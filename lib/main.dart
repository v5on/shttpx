import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:path/path.dart' as p;
import 'package:mime/mime.dart';

void main() {
  runApp(const ShttpxApp());
}

class ShttpxApp extends StatelessWidget {
  const ShttpxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'shttpx',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2563EB)), // Royal Blue
        appBarTheme: const AppBarTheme(centerTitle: true, elevation: 2),
        cardTheme: CardThemeData(elevation: 2, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2563EB), brightness: Brightness.dark),
        cardTheme: CardThemeData(elevation: 2, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
      ),
      themeMode: ThemeMode.system,
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  HttpServer? _server;
  String _ipAddress = "Checking Network...";
  String _serverUrl = "Offline";
  String _statusLog = "Select a folder to start hosting.";
  bool _isRunning = false;
  String? _selectedPath;
  
  // Settings
  bool _renderHtml = false;
  final int _port = 8080;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _getIpAddress();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _renderHtml = prefs.getBool('renderHtml') ?? false;
    });
  }

  Future<void> _getIpAddress() async {
    String ip = "Unknown";
    try {
      if (Platform.isWindows) {
        for (var interface in await NetworkInterface.list()) {
          for (var addr in interface.addresses) {
            if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
              ip = addr.address;
              break;
            }
          }
        }
      } else {
        final info = NetworkInfo();
        ip = await info.getWifiIP() ?? "No Wi-Fi";
      }
    } catch (e) { ip = "Error"; }
    if (mounted) setState(() => _ipAddress = ip);
  }

  Future<void> _pickDirectory() async {
    if (Platform.isAndroid) {
      if (!await Permission.manageExternalStorage.isGranted) {
        await Permission.manageExternalStorage.request();
      }
    }
    String? path = await FilePicker.platform.getDirectoryPath();
    if (path != null) {
      setState(() {
        _selectedPath = path;
        _statusLog = "Target: ${p.basename(path)}";
      });
    }
  }

  // --- SERVER LOGIC ---
  Future<void> _toggleServer() async {
    if (_isRunning) {
      await _server?.close(force: true);
      setState(() {
        _isRunning = false;
        _serverUrl = "Offline";
        _statusLog = "Server Stopped.";
      });
    } else {
      if (_selectedPath == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Please select a directory first.")));
        return;
      }

      try {
        // Custom Request Handler
        var handler = const Pipeline().addHandler((Request request) {
          final requestedPath = request.url.path;
          final localPath = p.join(_selectedPath!, Uri.decodeComponent(requestedPath));
          final file = File(localPath);
          final dir = Directory(localPath);

          // 1. Serve Index.html if enabled and exists
          if (_renderHtml && (requestedPath.isEmpty || requestedPath == '/')) {
            final indexFile = File(p.join(_selectedPath!, 'index.html'));
            if (indexFile.existsSync()) {
               return Response.ok(indexFile.openRead(), headers: {'Content-Type': 'text/html'});
            }
          }

          // 2. Serve File
          if (file.existsSync()) {
            final mimeType = lookupMimeType(file.path) ?? 'application/octet-stream';
            return Response.ok(file.openRead(), headers: {'Content-Type': mimeType});
          }

          // 3. Serve Directory Listing (Smart Web UI)
          if (dir.existsSync()) {
            return Response.ok(_generateSmartWebUI(dir, requestedPath), headers: {'Content-Type': 'text/html'});
          }

          return Response.notFound('File not found');
        });

        _server = await shelf_io.serve(handler, InternetAddress.anyIPv4, _port);
        
        setState(() {
          _isRunning = true;
          _serverUrl = "http://$_ipAddress:$_port";
          _statusLog = _renderHtml ? "✅ Website Hosted" : "✅ Smart File Server Online";
        });
      } catch (e) {
        setState(() => _statusLog = "Error: $e");
      }
    }
  }

  // --- SMART HTML GENERATOR ---
  String _generateSmartWebUI(Directory dir, String reqPath) {
    final contents = dir.listSync()
      ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    
    // Header & Info Button Logic embedded in HTML
    return '''
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>shttpx Files</title>
    <style>
        :root { --primary: #2563EB; --bg: #F8FAFC; --card: #FFFFFF; --text: #1E293B; }
        @media (prefers-color-scheme: dark) { :root { --primary: #3B82F6; --bg: #0F172A; --card: #1E293B; --text: #F1F5F9; } }
        
        body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: var(--bg); color: var(--text); }
        
        /* HEADER */
        .header { display: flex; justify-content: space-between; align-items: center; padding: 15px 20px; background: var(--card); box-shadow: 0 1px 3px rgba(0,0,0,0.1); position: sticky; top: 0; z-index: 10; }
        .brand { display: flex; align-items: center; gap: 10px; font-weight: bold; font-size: 20px; color: var(--primary); }
        .logo-box { width: 32px; height: 32px; background: var(--primary); border-radius: 8px; color: white; display: flex; align-items: center; justify-content: center; font-size: 18px; }
        
        .info-btn { background: none; border: 2px solid var(--text); color: var(--text); width: 28px; height: 28px; border-radius: 50%; font-weight: bold; cursor: pointer; opacity: 0.6; transition: 0.2s; }
        .info-btn:hover { opacity: 1; border-color: var(--primary); color: var(--primary); }

        /* LIST */
        .container { max-width: 800px; margin: 20px auto; padding: 0 15px; }
        .file-item { display: flex; align-items: center; padding: 15px; background: var(--card); border-radius: 10px; margin-bottom: 8px; text-decoration: none; color: inherit; transition: 0.2s; border: 1px solid transparent; }
        .file-item:hover { transform: translateY(-2px); border-color: var(--primary); }
        .icon { font-size: 24px; margin-right: 15px; }
        .name { flex-grow: 1; word-break: break-all; }
        .size { font-size: 12px; opacity: 0.6; }

        /* POPUP */
        .modal { display: none; position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.5); align-items: center; justify-content: center; z-index: 100; }
        .modal-box { background: var(--card); padding: 30px; border-radius: 15px; text-align: center; max-width: 300px; box-shadow: 0 10px 25px rgba(0,0,0,0.2); }
    </style>
</head>
<body>

    <div class="header">
        <div class="brand">
            <div class="logo-box">S</div> shttpx
        </div>
        <button class="info-btn" onclick="toggleModal()">i</button>
    </div>

    <div class="container">
        ${reqPath.length > 1 ? '<a href="../" class="file-item"><span class="icon">📂</span> <b>.. (Parent)</b></a>' : ''}
        ${contents.map((e) {
          final isDir = e is Directory;
          final name = p.basename(e.path);
          final icon = isDir ? '📁' : '📄';
          final link = isDir ? '$name/' : name;
          final size = isDir ? '' : '${(File(e.path).lengthSync() / 1024).toStringAsFixed(1)} KB';
          return '<a href="$link" class="file-item"><span class="icon">$icon</span><span class="name">$name</span><span class="size">$size</span></a>';
        }).join('')}
    </div>

    <div id="infoModal" class="modal" onclick="toggleModal()">
        <div class="modal-box" onclick="event.stopPropagation()">
            <h2 style="margin: 0 0 10px 0;">shttpx</h2>
            <p>Smart Local Cloud</p>
            <p style="font-size: 12px; opacity: 0.7;">Developed by Sultan Arabi</p>
            <button onclick="toggleModal()" style="margin-top: 15px; padding: 8px 20px; background: var(--primary); color: white; border: none; border-radius: 5px; cursor: pointer;">Close</button>
        </div>
    </div>

    <script>
        function toggleModal() {
            const m = document.getElementById('infoModal');
            m.style.display = m.style.display === 'flex' ? 'none' : 'flex';
        }
    </script>
</body>
</html>
    ''';
  }

  // --- APP UI ---
  void _openBrowser() => launchUrl(Uri.parse(_serverUrl));
  void _copyUrl() {
    Clipboard.setData(ClipboardData(text: _serverUrl));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Link Copied!")));
  }

  void _openSettings() {
    Navigator.push(context, MaterialPageRoute(builder: (c) => SettingsScreen(
      renderHtml: _renderHtml,
      onSave: (val) async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('renderHtml', val);
        setState(() => _renderHtml = val);
        if(_isRunning) { _toggleServer(); Future.delayed(const Duration(milliseconds: 200), _toggleServer); }
      }
    )));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("shttpx", style: TextStyle(fontWeight: FontWeight.bold)),
        // Logo Handling in App UI
        leading: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Image.asset('assets/logo.png', errorBuilder: (c,o,s)=>const Icon(Icons.dns)),
        ),
        actions: [
          IconButton(icon: const Icon(Icons.settings), onPressed: _isRunning ? null : _openSettings)
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 20),
              decoration: BoxDecoration(
                color: _isRunning ? Theme.of(context).colorScheme.primaryContainer : Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _isRunning ? Theme.of(context).colorScheme.primary : Colors.grey.withOpacity(0.2)),
              ),
              child: Column(
                children: [
                  Icon(_isRunning ? Icons.wifi_tethering : Icons.wifi_off, size: 60, color: _isRunning ? Theme.of(context).colorScheme.primary : Colors.grey),
                  const SizedBox(height: 15),
                  SelectableText(_isRunning ? _serverUrl : "Offline", style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: _isRunning ? Theme.of(context).colorScheme.primary : Colors.grey)),
                  const SizedBox(height: 5),
                  Text(_ipAddress),
                  if (_isRunning) ...[
                    const SizedBox(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        FilledButton.tonalIcon(onPressed: _copyUrl, icon: const Icon(Icons.copy, size: 18), label: const Text("Copy")),
                        const SizedBox(width: 10),
                        FilledButton.tonalIcon(onPressed: _openBrowser, icon: const Icon(Icons.open_in_browser, size: 18), label: const Text("Open")),
                      ],
                    )
                  ]
                ],
              ),
            ),
            const SizedBox(height: 30),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: Colors.grey.withOpacity(0.2))),
              leading: const Icon(Icons.folder_open, size: 30, color: Colors.orangeAccent),
              title: Text(_selectedPath == null ? "Select Folder" : p.basename(_selectedPath!), style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(_selectedPath == null ? "Tap to browse" : _selectedPath!),
              trailing: const Icon(Icons.edit, size: 20),
              onTap: _isRunning ? null : _pickDirectory,
            ),
            const Spacer(),
            Text(_statusLog, style: TextStyle(color: _isRunning ? Colors.green : Colors.grey, fontFamily: 'monospace')),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 55,
              child: FilledButton.icon(
                onPressed: _toggleServer,
                icon: Icon(_isRunning ? Icons.stop_circle_outlined : Icons.rocket_launch),
                label: Text(_isRunning ? "STOP SERVER" : "START SERVER", style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                style: FilledButton.styleFrom(backgroundColor: _isRunning ? Colors.redAccent : null),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SettingsScreen extends StatefulWidget {
  final bool renderHtml;
  final Function(bool) onSave;
  const SettingsScreen({super.key, required this.renderHtml, required this.onSave});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late bool _renderHtml;
  @override
  void initState() {
    super.initState();
    _renderHtml = widget.renderHtml;
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Settings")),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          SwitchListTile(
            title: const Text("Host Website Mode"),
            subtitle: const Text("Renders index.html if found."),
            value: _renderHtml,
            onChanged: (val) { setState(() => _renderHtml = val); widget.onSave(val); },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.info),
            title: const Text("About shttpx"),
            subtitle: const Text("v5.1.0 • Developed by Sultan Arabi"),
            onTap: () => launchUrl(Uri.parse('https://github.com/v5on')),
          )
        ],
      ),
    );
  }
}
