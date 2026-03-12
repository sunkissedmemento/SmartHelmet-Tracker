import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:another_telephony/telephony.dart';

void main() {
  runApp(const LocationSMSApp());
}

class Contact {
  final String name;
  final String number;
  Contact({required this.name, required this.number});
}

// ─── THEME ────────────────────────────────────────────────────
class AppTheme {
  static const accent       = Color(0xFF0A84FF);
  static const green        = Color(0xFF4ADE80);
  static const redAlert     = Color(0xFFFF4444);

  static const darkBg       = Color(0xFF0D1117);
  static const darkSurface  = Color(0xFF161B22);
  static const darkBorder   = Color(0xFF30363D);
  static const darkText     = Color(0xFFFFFFFF);
  static const darkSubtext  = Color(0xB3FFFFFF);
  static const darkHint     = Color(0x59FFFFFF);

  static const lightBg      = Color(0xFFF2F4F8);
  static const lightSurface = Color(0xFFFFFFFF);
  static const lightBorder  = Color(0xFFD0D7DE);
  static const lightText    = Color(0xFF1A1A2E);
  static const lightSubtext = Color(0xFF444C56);
  static const lightHint    = Color(0xFF8B949E);
}

// ─── APP ROOT ─────────────────────────────────────────────────
class LocationSMSApp extends StatefulWidget {
  const LocationSMSApp({super.key});
  static _LocationSMSAppState? of(BuildContext context) =>
      context.findAncestorStateOfType<_LocationSMSAppState>();

  @override
  State<LocationSMSApp> createState() => _LocationSMSAppState();
}

class _LocationSMSAppState extends State<LocationSMSApp> {
  bool isDark = true;
  void toggleTheme() => setState(() => isDark = !isDark);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Helmet Alert',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppTheme.accent,
          brightness: isDark ? Brightness.dark : Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: MapScreen(isDark: isDark),
    );
  }
}

// ─── MAIN SCREEN ──────────────────────────────────────────────
class MapScreen extends StatefulWidget {
  final bool isDark;
  const MapScreen({super.key, required this.isDark});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> with SingleTickerProviderStateMixin {
  final MapController _mapController = MapController();
  Position? _currentPosition;
  DateTime? _lastUpdated;
  bool _isLoading = false;
  bool _isSending = false;
  String _statusMessage = 'Getting location...';
  final List<Contact> _contacts = [];
  Timer? _tickTimer;
  Timer? _rescanTimer;
  StreamSubscription<Position>? _locationStream;
  bool _mapReady = false;

  // BLE
  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _notifyCharacteristic;
  StreamSubscription? _scanSubscription;
  StreamSubscription? _notifySubscription;
  StreamSubscription? _deviceStateSubscription;
  List<ScanResult> _scanResults = [];
  bool _isScanning = false;
  bool _isConnecting = false;
  String _bleStatus = 'Not connected';
  bool _collisionAlertShown = false;
  bool _sheetOpen = false;
  final Telephony _telephony = Telephony.instance;

  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;

  static const String SERVICE_UUID = '4fafc201-1fb5-459e-8fcc-c5c9c331914b';
  static const String CHARACTERISTIC_UUID = 'beb5483e-36e1-4688-b7f5-ea07361b26a8';

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(begin: 0.35, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    _checkBluetooth();
    _initLocation();
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _lastUpdated != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _scanSubscription?.cancel();
    _notifySubscription?.cancel();
    _deviceStateSubscription?.cancel();
    _rescanTimer?.cancel();
    _locationStream?.cancel();
    _tickTimer?.cancel();
    super.dispose();
  }

  // ─── PERMISSIONS ────────────────────────────────────────────
  Future<void> _checkBluetooth() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
      Permission.sms,
    ].request();
  }

  Future<void> _initLocation() async {
    await [Permission.location].request();
    await _startLocationStream();
  }

  // ─── GPS ────────────────────────────────────────────────────
  Future<void> _startLocationStream() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() { _statusMessage = 'Location services disabled'; _isLoading = false; });
      return;
    }
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        setState(() { _statusMessage = 'Location permission denied'; _isLoading = false; });
        return;
      }
    }
    setState(() => _isLoading = true);
    try {
      final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      _updatePosition(pos);
    } catch (_) {}
    _locationStream?.cancel();
    _locationStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
        timeLimit: Duration(seconds: 10),
      ),
    ).listen(
      _updatePosition,
      onError: (_) => setState(() { _statusMessage = 'Location error'; _isLoading = false; }),
    );
    Timer.periodic(const Duration(seconds: 10), (t) async {
      if (!mounted) { t.cancel(); return; }
      try {
        final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
        _updatePosition(pos);
      } catch (_) {}
    });
  }

  void _updatePosition(Position position) {
    if (!mounted) return;
    setState(() {
      _currentPosition = position;
      _lastUpdated = DateTime.now();
      _isLoading = false;
      _statusMessage = '${position.latitude.toStringAsFixed(6)}, ${position.longitude.toStringAsFixed(6)}';
    });
    if (_mapReady) {
      _mapController.move(
        LatLng(position.latitude, position.longitude), _mapController.camera.zoom);
    }
  }

  Future<void> _refreshLocation() async {
    setState(() => _isLoading = true);
    try {
      final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      _updatePosition(pos);
    } catch (_) {
      setState(() { _isLoading = false; _statusMessage = 'Error getting location'; });
    }
  }

  String _timeAgoLabel() {
    if (_lastUpdated == null) return '';
    final secs = DateTime.now().difference(_lastUpdated!).inSeconds;
    if (secs < 5) return 'just now';
    if (secs < 60) return '${secs}s ago';
    return '${secs ~/ 60}m ago';
  }

  // ─── BLE ────────────────────────────────────────────────────
  void _startScan() {
    if (_isScanning) return;
    setState(() => _isScanning = true);
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));
    _scanSubscription?.cancel();
    _scanSubscription = FlutterBluePlus.scanResults.listen((r) {
      if (mounted) setState(() => _scanResults = r);
    });
    FlutterBluePlus.isScanning.listen((scanning) {
      if (!scanning && mounted) setState(() => _isScanning = false);
    });
  }

  void _startAutoScan() {
    _rescanTimer?.cancel();
    _scanResults = [];
    _startScan();
    _rescanTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_sheetOpen && _connectedDevice == null) _startScan();
    });
  }

  void _stopScan() {
    _rescanTimer?.cancel();
    FlutterBluePlus.stopScan();
    setState(() => _isScanning = false);
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    _stopScan();
    setState(() { _isConnecting = true; _bleStatus = 'Connecting...'; });
    try {
      await device.connect(timeout: const Duration(seconds: 10));
      _deviceStateSubscription?.cancel();
      _deviceStateSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected && mounted) {
          setState(() { _connectedDevice = null; _notifyCharacteristic = null; _bleStatus = 'Not connected'; });
        }
      });
      List<BluetoothService> services = await device.discoverServices();
      BluetoothCharacteristic? found;
      for (var svc in services) {
        for (var c in svc.characteristics) {
          if (c.uuid.toString().toLowerCase() == CHARACTERISTIC_UUID.toLowerCase()) { found = c; break; }
          if (c.properties.notify && found == null) found = c;
        }
        if (found != null) break;
      }
      if (found != null) {
        await found.setNotifyValue(true);
        _notifySubscription?.cancel();
        _notifySubscription = found.onValueReceived.listen((value) {
          final data = utf8.decode(value).trim().toUpperCase();
          if (data.contains('COLLISION') || data.contains('ALERT') || data == '1') {
            _onCollisionDetected();
          }
        });
        setState(() {
          _connectedDevice = device;
          _notifyCharacteristic = found;
          _isConnecting = false;
          _bleStatus = 'Connected · ${device.platformName}';
        });
      } else {
        await device.disconnect();
        setState(() { _isConnecting = false; _bleStatus = 'No characteristic found'; });
      }
    } catch (_) {
      setState(() { _isConnecting = false; _bleStatus = 'Connection failed'; });
    }
  }

  Future<void> _disconnect() async {
    await _connectedDevice?.disconnect();
    _notifySubscription?.cancel();
    setState(() { _connectedDevice = null; _notifyCharacteristic = null; _bleStatus = 'Not connected'; });
  }

  // ─── COLLISION ──────────────────────────────────────────────
  Future<void> _onCollisionDetected() async {
    if (_collisionAlertShown) return;
    if (!mounted) return;
    await _refreshLocation();
    if (!mounted) return;
    setState(() => _collisionAlertShown = true);
  }

  void _showCollisionSheet({bool isAutomatic = false}) {
    setState(() => _collisionAlertShown = true);
  }

  // ─── SMS ────────────────────────────────────────────────────
  Future<void> _sendSMSToContact(Contact contact) async {
    if (_currentPosition == null) return;
    final lat = _currentPosition!.latitude;
    final lng = _currentPosition!.longitude;
    final msg = '🚨 COLLISION ALERT!\nHelmet impact detected.\nLocation: $lat, $lng\nhttps://maps.google.com/?q=$lat,$lng';
    try {
      _telephony.sendSms(to: contact.number, message: msg);
    } catch (e) {
      debugPrint('[SMS] $e');
    }
  }

  Future<void> _sendManualSMS(Contact contact) async {
    if (_currentPosition == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Get location first!'),
        backgroundColor: Colors.orange,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
      return;
    }
    setState(() => _isSending = true);
    final bool? granted = await _telephony.requestPhoneAndSmsPermissions;
    if (granted != true) { setState(() => _isSending = false); return; }
    final lat = _currentPosition!.latitude;
    final lng = _currentPosition!.longitude;
    final msg = '📍 My current location:\n$lat, $lng\nhttps://maps.google.com/?q=$lat,$lng';
    try {
      _telephony.sendSms(to: contact.number, message: msg);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('✅ Sent to ${contact.name}'),
        backgroundColor: const Color(0xFF1A3A1A),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
    } catch (e) { debugPrint('[SMS] $e'); }
    setState(() => _isSending = false);
  }

  // ─── SHEETS ─────────────────────────────────────────────────
  void _showScanSheet() {
    _sheetOpen = true;
    _startAutoScan();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        _scanSubscription?.cancel();
        _scanSubscription = FlutterBluePlus.scanResults.listen((r) {
          if (mounted) { setState(() => _scanResults = r); setSheet(() {}); }
        });
        return _BottomSheet(
          isDark: widget.isDark,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const _SheetHandle(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text('Select Helmet', style: TextStyle(
                  color: widget.isDark ? AppTheme.darkText : AppTheme.lightText,
                  fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: 0.5,
                )),
                Row(children: [
                  if (_isScanning)
                    const SizedBox(width: 14, height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.accent)),
                  const SizedBox(width: 6),
                  Text(_isScanning ? 'Scanning...' : 'Next in 5s',
                    style: TextStyle(
                      color: widget.isDark ? AppTheme.darkHint : AppTheme.lightHint,
                      fontSize: 11, fontFamily: 'monospace',
                    )),
                ]),
              ]),
            ),
            Divider(color: widget.isDark ? AppTheme.darkBorder : AppTheme.lightBorder, height: 20),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.45),
              child: _scanResults.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 36),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.bluetooth_searching,
                        color: widget.isDark ? AppTheme.darkHint : AppTheme.lightHint, size: 48),
                      const SizedBox(height: 12),
                      Text('Scanning for nearby devices...',
                        style: TextStyle(color: widget.isDark ? AppTheme.darkHint : AppTheme.lightHint)),
                      const SizedBox(height: 4),
                      Text('Make sure helmet is powered on',
                        style: TextStyle(
                          color: widget.isDark ? const Color(0x40FFFFFF) : AppTheme.lightHint, fontSize: 12)),
                    ]),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: _scanResults.length,
                    itemBuilder: (_, i) {
                      final r = _scanResults[i];
                      final name = r.device.platformName.isNotEmpty ? r.device.platformName : 'Unknown Device';
                      return _DeviceRow(
                        name: name,
                        mac: r.device.remoteId.str,
                        rssi: r.rssi,
                        goodSignal: r.rssi > -60,
                        isDark: widget.isDark,
                        onTap: () { Navigator.pop(ctx); _connectToDevice(r.device); },
                      );
                    },
                  ),
            ),
            const SizedBox(height: 16),
          ]),
        );
      }),
    ).whenComplete(() { _sheetOpen = false; _stopScan(); });
  }

  void _showContactsSheet() {
    if (_contacts.isEmpty) { _showAddContactDialog(); return; }
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) => _BottomSheet(
        isDark: widget.isDark,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const _SheetHandle(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('Send to...', style: TextStyle(
                color: widget.isDark ? AppTheme.darkText : AppTheme.lightText,
                fontSize: 18, fontWeight: FontWeight.w800,
              )),
              GestureDetector(
                onTap: () { Navigator.pop(ctx); _showAddContactDialog(); },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppTheme.accent.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text('+ New',
                    style: TextStyle(color: AppTheme.accent, fontSize: 12, fontWeight: FontWeight.w700)),
                ),
              ),
            ]),
          ),
          Divider(color: widget.isDark ? AppTheme.darkBorder : AppTheme.lightBorder, height: 20),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.4),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _contacts.length,
              itemBuilder: (_, i) => _ContactRow(
                contact: _contacts[i],
                isDark: widget.isDark,
                onSms: () { Navigator.pop(ctx); _sendManualSMS(_contacts[i]); },
                onDelete: () { setState(() => _contacts.removeAt(i)); setSheet(() {}); },
              ),
            ),
          ),
          const SizedBox(height: 16),
        ]),
      )),
    );
  }

  void _showAddContactDialog() {
    final nameCtrl = TextEditingController();
    final numCtrl  = TextEditingController();
    final formKey  = GlobalKey<FormState>();
    final bg   = widget.isDark ? AppTheme.darkSurface : AppTheme.lightSurface;
    final txt  = widget.isDark ? AppTheme.darkText    : AppTheme.lightText;
    final hint = widget.isDark ? AppTheme.darkHint    : AppTheme.lightHint;
    final bdr  = widget.isDark ? AppTheme.darkBorder  : AppTheme.lightBorder;
    final fill = widget.isDark ? AppTheme.darkBg      : AppTheme.lightBg;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: bg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Row(children: [
          const Icon(Icons.person_add_rounded, color: AppTheme.accent, size: 20),
          const SizedBox(width: 8),
          Text('Add Contact', style: TextStyle(color: txt, fontSize: 17, fontWeight: FontWeight.w800)),
        ]),
        content: Form(
          key: formKey,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextFormField(
              controller: nameCtrl,
              style: TextStyle(color: txt, fontFamily: 'monospace'),
              decoration: _inputDeco('Name', Icons.person_outline, fill, bdr, hint),
              validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter a name' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: numCtrl,
              style: TextStyle(color: txt, fontFamily: 'monospace'),
              keyboardType: TextInputType.phone,
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9+]'))],
              decoration: _inputDeco('Phone Number', Icons.phone_outlined, fill, bdr, hint),
              validator: (v) => (v == null || v.trim().length < 7) ? 'Enter a valid number' : null,
            ),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: hint)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accent, foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            ),
            onPressed: () {
              if (formKey.currentState!.validate()) {
                setState(() => _contacts.add(Contact(name: nameCtrl.text.trim(), number: numCtrl.text.trim())));
                Navigator.pop(ctx);
              }
            },
            child: const Text('Add', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  InputDecoration _inputDeco(String label, IconData icon, Color fill, Color bdr, Color hint) =>
    InputDecoration(
      labelText: label,
      labelStyle: TextStyle(color: hint, fontSize: 13),
      prefixIcon: Icon(icon, color: AppTheme.accent, size: 18),
      filled: true, fillColor: fill,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: bdr)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: bdr)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: AppTheme.accent, width: 1.5)),
      errorStyle: const TextStyle(color: Colors.redAccent, fontSize: 11),
    );

  // ─── BUILD ──────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final isDark    = widget.isDark;
    final bg        = isDark ? AppTheme.darkBg      : AppTheme.lightBg;
    final surface   = isDark ? AppTheme.darkSurface  : AppTheme.lightSurface;
    final border    = isDark ? AppTheme.darkBorder   : AppTheme.lightBorder;
    final textColor = isDark ? AppTheme.darkText     : AppTheme.lightText;
    final subtext   = isDark ? AppTheme.darkSubtext  : AppTheme.lightSubtext;
    final hint      = isDark ? AppTheme.darkHint     : AppTheme.lightHint;

    final hasLocation = _currentPosition != null;
    final isConnected = _connectedDevice != null;
    final center = hasLocation
        ? LatLng(_currentPosition!.latitude, _currentPosition!.longitude)
        : const LatLng(14.5995, 120.9842);

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('HELMET ALERT', style: TextStyle(
          color: textColor, fontSize: 17,
          fontWeight: FontWeight.w800, letterSpacing: 2.0,
        )),
        centerTitle: false,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, color: border),
        ),
        actions: [
          _AppBarBtn(
            icon: isDark ? Icons.wb_sunny_rounded : Icons.nights_stay_rounded,
            onTap: () => LocationSMSApp.of(context)?.toggleTheme(),
          ),
          Stack(alignment: Alignment.center, children: [
            _AppBarBtn(icon: Icons.contacts_rounded, onTap: _showContactsSheet),
            if (_contacts.isNotEmpty)
              Positioned(
                top: 8, right: 8,
                child: Container(
                  width: 15, height: 15,
                  decoration: const BoxDecoration(color: AppTheme.accent, shape: BoxShape.circle),
                  child: Center(child: Text('${_contacts.length}',
                    style: const TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold))),
                ),
              ),
          ]),
          _AppBarBtn(
            icon: Icons.my_location_rounded,
            onTap: _isLoading ? null : _refreshLocation,
            isLoading: _isLoading,
          ),
          const SizedBox(width: 4),
        ],
      ),

      body: Stack(children: [
        Column(children: [

        // ── GPS Status Bar ──────────────────────────────────
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
          decoration: BoxDecoration(
            color: surface,
            border: Border(bottom: BorderSide(color: border, width: 1)),
          ),
          child: Row(children: [
            const Icon(Icons.location_on_rounded, size: 13, color: AppTheme.accent),
            const SizedBox(width: 7),
            Expanded(child: Text(_statusMessage,
              style: TextStyle(color: subtext, fontSize: 11, fontFamily: 'monospace'),
              overflow: TextOverflow.ellipsis)),
            if (hasLocation) ...[
              AnimatedBuilder(
                animation: _pulseAnim,
                builder: (_, __) => Opacity(
                  opacity: _pulseAnim.value,
                  child: Container(width: 6, height: 6,
                    decoration: const BoxDecoration(color: AppTheme.green, shape: BoxShape.circle)),
                ),
              ),
              const SizedBox(width: 5),
              const Text('LIVE', style: TextStyle(
                color: AppTheme.green, fontSize: 9,
                fontWeight: FontWeight.w800, letterSpacing: 1.5,
              )),
            ],
          ]),
        ),

        // ── BLE Bar ─────────────────────────────────────────
        GestureDetector(
          onTap: isConnected ? _disconnect : _showScanSheet,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
            color: isConnected
              ? (isDark ? const Color(0xFF0A2A0A) : const Color(0xFFE6F4EA))
              : (isDark ? const Color(0xFF1A1A0A) : const Color(0xFFFFF8E1)),
            child: Row(children: [
              _isConnecting
                ? const SizedBox(width: 13, height: 13,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange))
                : Icon(
                    isConnected ? Icons.bluetooth_connected_rounded : Icons.bluetooth_disabled_rounded,
                    size: 13,
                    color: isConnected ? AppTheme.green : Colors.orange,
                  ),
              const SizedBox(width: 8),
              Expanded(child: Text(_bleStatus,
                style: TextStyle(
                  color: isConnected ? AppTheme.green : Colors.orange,
                  fontSize: 11, fontFamily: 'monospace', fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis)),
              Text(isConnected ? 'Tap to disconnect' : 'Tap to scan',
                style: TextStyle(color: hint, fontSize: 10)),
            ]),
          ),
        ),

        // ── Map ─────────────────────────────────────────────
        Expanded(
          child: FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: center,
              initialZoom: 15.0,
              interactionOptions: const InteractionOptions(flags: InteractiveFlag.all),
              onMapReady: () {
                setState(() => _mapReady = true);
                if (_currentPosition != null) {
                  _mapController.move(
                    LatLng(_currentPosition!.latitude, _currentPosition!.longitude), 15.0);
                }
              },
            ),
            children: [
              TileLayer(
                urlTemplate: isDark
                  ? 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png'
                  : 'https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png',
                subdomains: const ['a', 'b', 'c', 'd'],
                userAgentPackageName: 'com.example.location_sms',
              ),
              if (hasLocation)
                MarkerLayer(markers: [
                  Marker(
                    point: LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
                    width: 24, height: 24,
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppTheme.accent,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 3),
                        boxShadow: [BoxShadow(
                          color: AppTheme.accent.withOpacity(0.7),
                          blurRadius: 14, spreadRadius: 4,
                        )],
                      ),
                    ),
                  ),
                ]),
            ],
          ),
        ),

        // ── Bottom Panel ────────────────────────────────────
        Container(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
          decoration: BoxDecoration(
            color: surface,
            border: Border(top: BorderSide(color: border)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [

            if (hasLocation) ...[
              // GPS header row
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                const Text('GPS', style: TextStyle(
                  color: AppTheme.accent, fontSize: 9,
                  fontWeight: FontWeight.w900, letterSpacing: 2.5,
                )),
                Row(children: [
                  AnimatedBuilder(
                    animation: _pulseAnim,
                    builder: (_, __) => Opacity(
                      opacity: _pulseAnim.value,
                      child: Container(width: 5, height: 5,
                        decoration: const BoxDecoration(color: AppTheme.green, shape: BoxShape.circle)),
                    ),
                  ),
                  const SizedBox(width: 5),
                  Text(_timeAgoLabel(), style: TextStyle(
                    color: hint, fontSize: 10, fontFamily: 'monospace',
                  )),
                ]),
              ]),
              const SizedBox(height: 8),

              // Coord cards row
              Row(children: [
                _CoordCard(label: 'LAT',
                  value: _currentPosition!.latitude.toStringAsFixed(6), isDark: isDark),
                const SizedBox(width: 8),
                _CoordCard(label: 'LNG',
                  value: _currentPosition!.longitude.toStringAsFixed(6), isDark: isDark),
              ]),
              const SizedBox(height: 12),
            ],

            _OutlineBtn(
              label: _isConnecting ? 'Connecting...'
                : isConnected ? 'Helmet Connected — Disconnect'
                : 'Connect to Helmet',
              icon: isConnected
                ? Icons.bluetooth_connected_rounded
                : Icons.bluetooth_searching_rounded,
              color: isConnected ? AppTheme.green : AppTheme.accent,
              onTap: isConnected ? _disconnect : _showScanSheet,
              loading: _isConnecting,
            ),
            const SizedBox(height: 8),

            _PrimaryBtn(
              label: _isSending ? 'Sending...'
                : _contacts.isEmpty ? 'Add Contact & Send SMS'
                : 'Send Location via SMS',
              icon: Icons.sms_rounded,
              onTap: _isSending ? null : () {
                if (_contacts.isEmpty) { _showAddContactDialog(); return; }
                _showContactsSheet();
              },
              loading: _isSending,
            ),

            if (isConnected) ...[
              const SizedBox(height: 8),
              _contacts.isNotEmpty
                ? Row(mainAxisAlignment: MainAxisAlignment.center, children: const [
                    Icon(Icons.shield_rounded, size: 12, color: AppTheme.green),
                    SizedBox(width: 5),
                    Text('Monitoring for collision...',
                      style: TextStyle(color: AppTheme.green, fontSize: 11)),
                  ])
                : Row(mainAxisAlignment: MainAxisAlignment.center, children: const [
                    Icon(Icons.warning_amber_rounded, size: 12, color: Colors.orange),
                    SizedBox(width: 5),
                    Text('Add contacts to enable alerts',
                      style: TextStyle(color: Colors.orange, fontSize: 11)),
                  ]),
            ],
          ]),
        ),
        ]),  // end Column

        // ── Collision Overlay (full-screen, like HTML) ──────
        if (_collisionAlertShown)
          _CollisionOverlay(
            contacts: List.from(_contacts),
            position: _currentPosition,
            onDismiss: () {
              setState(() => _collisionAlertShown = false);
              Future.delayed(const Duration(seconds: 5), () => _collisionAlertShown = false);
            },
            onSend: _sendSMSToContact,
          ),

      ]),  // end Stack

      floatingActionButton: FloatingActionButton(
        onPressed: _showAddContactDialog,
        backgroundColor: AppTheme.accent,
        foregroundColor: Colors.white,
        elevation: 6,
        shape: const CircleBorder(),
        child: const Icon(Icons.person_add_rounded),
      ),
    );
  }
}

// ─── COLLISION OVERLAY (full-screen like HTML) ────────────────
class _CollisionOverlay extends StatefulWidget {
  final List<Contact> contacts;
  final Position? position;
  final VoidCallback onDismiss;
  final Future<void> Function(Contact) onSend;

  const _CollisionOverlay({
    required this.contacts, required this.position,
    required this.onDismiss, required this.onSend,
  });

  @override
  State<_CollisionOverlay> createState() => _CollisionOverlayState();
}

class _CollisionOverlayState extends State<_CollisionOverlay> with SingleTickerProviderStateMixin {
  late AnimationController _progressCtrl;
  late Animation<double> _progressAnim;
  final List<bool> _sent = [];
  bool _allDone = false;

  @override
  void initState() {
    super.initState();
    _sent.addAll(List.filled(widget.contacts.length, false));
    _progressCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 2));
    _progressAnim = Tween<double>(begin: 0, end: 1)
      .animate(CurvedAnimation(parent: _progressCtrl, curve: Curves.linear));
    _progressCtrl.forward();
    _sendAll();
  }

  Future<void> _sendAll() async {
    await Future.delayed(const Duration(milliseconds: 200));
    for (int i = 0; i < widget.contacts.length; i++) {
      await widget.onSend(widget.contacts[i]);
      if (mounted) setState(() => _sent[i] = true);
      await Future.delayed(const Duration(milliseconds: 400));
    }
    if (mounted) setState(() => _allDone = true);
  }

  @override
  void dispose() { _progressCtrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final lat = widget.position?.latitude.toStringAsFixed(6) ?? '—';
    final lng = widget.position?.longitude.toStringAsFixed(6) ?? '—';

    return Container(
      color: const Color(0xB2780000), // rgba(120,0,0,0.7)
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1A0000),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFFF3333)),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [

          // Title
          Row(children: const [
            Icon(Icons.warning_amber_rounded, color: Color(0xFFFF3333), size: 22),
            SizedBox(width: 8),
            Text('COLLISION DETECTED', style: TextStyle(
              color: Color(0xFFFF3333), fontSize: 15,
              fontWeight: FontWeight.w800,
            )),
          ]),
          const SizedBox(height: 12),

          // Progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: AnimatedBuilder(
              animation: _progressAnim,
              builder: (_, __) => LinearProgressIndicator(
                value: _progressAnim.value, minHeight: 6,
                backgroundColor: Colors.white.withOpacity(0.1),
                color: const Color(0xFFFF3333),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Contact rows
          if (widget.contacts.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('No contacts to notify.',
                style: TextStyle(color: Colors.white54, fontSize: 12)),
            )
          else
            ...List.generate(widget.contacts.length, (i) {
              final done = _sent.length > i && _sent[i];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  SizedBox(
                    width: 16, height: 16,
                    child: done
                      ? const Icon(Icons.check_circle, color: Color(0xFF4ADE80), size: 16)
                      : const CircularProgressIndicator(strokeWidth: 2, color: Colors.white38),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${widget.contacts[i].name} — ${done ? "Sent" : "Sending..."}',
                    style: TextStyle(
                      color: done ? const Color(0xFF4ADE80) : Colors.white60,
                      fontSize: 12,
                    ),
                  ),
                ]),
              );
            }),

          const SizedBox(height: 8),

          // Coords
          Align(
            alignment: Alignment.centerLeft,
            child: Text('$lat, $lng',
              style: TextStyle(
                color: Colors.white.withOpacity(0.4),
                fontSize: 11, fontFamily: 'monospace',
              )),
          ),

          // Dismiss button
          const SizedBox(height: 14),
          GestureDetector(
            onTap: _allDone ? widget.onDismiss : null,
            child: AnimatedOpacity(
              opacity: _allDone ? 1.0 : 0.4,
              duration: const Duration(milliseconds: 300),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFFFF3333),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text('Dismiss', textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w700,
                    fontSize: 13, fontFamily: 'monospace',
                  )),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

// ─── SHARED COMPONENTS ────────────────────────────────────────

class _AppBarBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final bool isLoading;
  const _AppBarBtn({required this.icon, this.onTap, this.isLoading = false});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: 36, height: 36,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      child: Center(
        child: isLoading
          ? const SizedBox(width: 18, height: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.accent))
          : Icon(icon, color: AppTheme.accent, size: 20),
      ),
    ),
  );
}

class _BottomSheet extends StatelessWidget {
  final bool isDark;
  final Widget child;
  const _BottomSheet({required this.isDark, required this.child});

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
      border: Border.all(
        color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder, width: 0.5),
    ),
    child: child,
  );
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 4),
    child: Center(child: Container(
      width: 36, height: 4,
      decoration: BoxDecoration(
        color: Colors.grey.withOpacity(0.3),
        borderRadius: BorderRadius.circular(2),
      ),
    )),
  );
}

class _CoordCard extends StatelessWidget {
  final String label, value;
  final bool isDark, expanded;
  const _CoordCard({required this.label, required this.value, required this.isDark, this.expanded = false});

  @override
  Widget build(BuildContext context) {
    final card = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkBg : AppTheme.lightBg,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(
          color: AppTheme.accent, fontSize: 8,
          fontWeight: FontWeight.w900, letterSpacing: 2.5, fontFamily: 'monospace',
        )),
        const SizedBox(height: 3),
        Text(value, style: TextStyle(
          color: isDark ? AppTheme.darkText : AppTheme.lightText,
          fontSize: 12, fontFamily: 'monospace',
        )),
      ]),
    );
    return expanded
      ? SizedBox(width: double.infinity, child: card)
      : Expanded(child: card);
  }
}

class _DeviceRow extends StatelessWidget {
  final String name, mac;
  final int rssi;
  final bool goodSignal, isDark;
  final VoidCallback onTap;
  const _DeviceRow({required this.name, required this.mac, required this.rssi,
    required this.goodSignal, required this.isDark, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(children: [
        Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
            color: AppTheme.accent.withOpacity(0.1), shape: BoxShape.circle),
          child: const Icon(Icons.bluetooth_rounded, color: AppTheme.accent, size: 18),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(name, style: TextStyle(
            color: isDark ? AppTheme.darkText : AppTheme.lightText,
            fontSize: 13, fontWeight: FontWeight.w700,
          )),
          Text(mac, style: TextStyle(
            color: isDark ? AppTheme.darkHint : AppTheme.lightHint,
            fontSize: 10, fontFamily: 'monospace',
          )),
        ])),
        Text('$rssi dBm', style: TextStyle(
          color: goodSignal ? AppTheme.green
            : rssi > -75 ? Colors.amber
            : (isDark ? AppTheme.darkHint : AppTheme.lightHint),
          fontSize: 11, fontFamily: 'monospace',
        )),
      ]),
    ),
  );
}

class _ContactRow extends StatelessWidget {
  final Contact contact;
  final bool isDark;
  final VoidCallback onSms, onDelete;
  const _ContactRow({required this.contact, required this.isDark, required this.onSms, required this.onDelete});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
    child: Row(children: [
      CircleAvatar(
        radius: 18,
        backgroundColor: AppTheme.accent.withOpacity(0.12),
        child: Text(contact.name[0].toUpperCase(),
          style: const TextStyle(color: AppTheme.accent, fontWeight: FontWeight.w800, fontSize: 14)),
      ),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(contact.name, style: TextStyle(
          color: isDark ? AppTheme.darkText : AppTheme.lightText,
          fontSize: 13, fontWeight: FontWeight.w700,
        )),
        Text(contact.number, style: TextStyle(
          color: isDark ? AppTheme.darkHint : AppTheme.lightHint,
          fontSize: 11, fontFamily: 'monospace',
        )),
      ])),
      IconButton(icon: const Icon(Icons.sms_rounded, size: 20, color: AppTheme.accent), onPressed: onSms, splashRadius: 20),
      IconButton(icon: const Icon(Icons.delete_outline_rounded, size: 20, color: Colors.redAccent), onPressed: onDelete, splashRadius: 20),
    ]),
  );
}

class _OutlineBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;
  final bool loading;
  const _OutlineBtn({required this.label, required this.icon, required this.color, this.onTap, this.loading = false});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 13),
      decoration: BoxDecoration(
        border: Border.all(color: color, width: 1.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        loading
          ? SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2, color: color))
          : Icon(icon, color: color, size: 15),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(
          color: color, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.3,
        )),
      ]),
    ),
  );
}

class _PrimaryBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool loading;
  const _PrimaryBtn({required this.label, required this.icon, this.onTap, this.loading = false});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: AnimatedOpacity(
      opacity: onTap == null ? 0.5 : 1.0,
      duration: const Duration(milliseconds: 200),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 13),
        decoration: BoxDecoration(
          color: AppTheme.accent,
          borderRadius: BorderRadius.circular(12),
          boxShadow: onTap != null
            ? [BoxShadow(color: AppTheme.accent.withOpacity(0.3), blurRadius: 12, offset: const Offset(0, 4))]
            : null,
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          loading
            ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : Icon(icon, color: Colors.white, size: 15),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(
            color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.3,
          )),
        ]),
      ),
    ),
  );
}