import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'services/meshtastic_service.dart';
import 'screens/settings_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/requests_screen.dart';
import 'models/chat_message.dart';

void main() {
  runApp(const SiriusPorteriaApp());
}

class SiriusPorteriaApp extends StatelessWidget {
  const SiriusPorteriaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sirius Portería',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          secondary: Colors.green,
        ),
        useMaterial3: true,
      ),
      home: const StartupScreen(),
    );
  }
}

class StartupScreen extends StatefulWidget {
  const StartupScreen({super.key});

  @override
  State<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<StartupScreen> {
  final _meshtasticService = MeshtasticService();

  @override
  void initState() {
    super.initState();
    _checkSavedDevice();
  }

  Future<void> _checkSavedDevice() async {
    final savedAddress = await _meshtasticService.getSavedDeviceAddress();

    if (!mounted) return;

    if (savedAddress != null) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) =>
              MainScreen(meshtasticService: _meshtasticService),
        ),
      );
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) =>
              DeviceSelectionScreen(meshtasticService: _meshtasticService),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.bluetooth_searching,
              size: 64,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 24),
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            const Text('Cargando...'),
          ],
        ),
      ),
    );
  }
}

class DeviceSelectionScreen extends StatefulWidget {
  final MeshtasticService meshtasticService;

  const DeviceSelectionScreen({super.key, required this.meshtasticService});

  @override
  State<DeviceSelectionScreen> createState() => _DeviceSelectionScreenState();
}

class _DeviceSelectionScreenState extends State<DeviceSelectionScreen> {
  final List<ScannedDevice> _devices = [];
  bool _isScanning = false;
  bool _permissionsGranted = false;
  String? _permissionError;
  StreamSubscription<ScannedDevice>? _scanSubscription;

  @override
  void initState() {
    super.initState();
    _checkPermissionsAndScan();
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    super.dispose();
  }

  Future<void> _checkPermissionsAndScan() async {
    setState(() {
      _permissionError = null;
    });

    final denied = <String>[];

    if (Platform.isAndroid) {
      // Android: permisos BLE específicos
      final bluetoothScan = await Permission.bluetoothScan.request();
      final bluetoothConnect = await Permission.bluetoothConnect.request();
      final location = await Permission.locationWhenInUse.request();

      // Permiso legacy (no fallar si no aplica)
      try {
        await Permission.bluetooth.request();
      } catch (_) {}

      if (!bluetoothScan.isGranted) denied.add('Bluetooth Scan');
      if (!bluetoothConnect.isGranted) denied.add('Bluetooth Connect');
      if (!location.isGranted) denied.add('Ubicacion');
    } else if (Platform.isIOS) {
      // iOS: solo permiso de Bluetooth
      final bluetooth = await Permission.bluetooth.request();
      if (!bluetooth.isGranted) denied.add('Bluetooth');
    }

    if (denied.isNotEmpty) {
      setState(() {
        _permissionsGranted = false;
        _permissionError = Platform.isIOS
            ? 'Permiso de Bluetooth denegado.\nVaya a Ajustes > Sirius Porteria > Bluetooth para habilitarlo.'
            : 'Permisos denegados: ${denied.join(", ")}.\nVaya a Configuracion > Apps > Sirius Porteria > Permisos para habilitarlos.';
      });
      return;
    }

    setState(() {
      _permissionsGranted = true;
      _permissionError = null;
    });

    _startScanning();
  }

  void _startScanning() {
    setState(() {
      _devices.clear();
      _isScanning = true;
    });

    _scanSubscription = widget.meshtasticService.scanDevices().listen(
      (device) {
        setState(() {
          final exists = _devices.any((d) => d.address == device.address);
          if (!exists) {
            _devices.add(device);
          }
        });
      },
      onDone: () {
        setState(() => _isScanning = false);
      },
      onError: (e) {
        setState(() => _isScanning = false);
      },
    );
  }

  Future<void> _selectDevice(ScannedDevice device) async {
    await widget.meshtasticService.connectToDevice(device);

    if (!mounted) return;

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) =>
            MainScreen(meshtasticService: widget.meshtasticService),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Seleccionar Dispositivo'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          if (!_isScanning)
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _startScanning,
              tooltip: 'Escanear de nuevo',
            ),
        ],
      ),
      body: Column(
        children: [
          if (_isScanning) const LinearProgressIndicator(),
          // Error de permisos
          if (_permissionError != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              color: Colors.red.shade50,
              child: Column(
                children: [
                  const Icon(Icons.warning_amber, color: Colors.red, size: 48),
                  const SizedBox(height: 12),
                  Text(
                    _permissionError!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.red.shade700, fontSize: 14),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton.icon(
                        onPressed: () => openAppSettings(),
                        icon: const Icon(Icons.settings),
                        label: const Text('Abrir Configuracion'),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: _checkPermissionsAndScan,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Reintentar'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          if (_permissionsGranted) ...[
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                children: [
                  Icon(
                    Icons.bluetooth_searching,
                    color: _isScanning ? Colors.blue : Colors.grey,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    _isScanning
                        ? 'Buscando dispositivos Meshtastic...'
                        : 'Dispositivos encontrados: ${_devices.length}',
                    style: const TextStyle(fontSize: 16),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
          ],
          Expanded(
            child: _devices.isEmpty && _permissionsGranted
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _isScanning
                              ? Icons.bluetooth_searching
                              : Icons.bluetooth_disabled,
                          size: 64,
                          color: Colors.grey,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _isScanning
                              ? 'Escaneando...'
                              : 'No se encontraron dispositivos',
                          style: TextStyle(
                            fontSize: 16,
                            color: Colors.grey.shade600,
                          ),
                        ),
                        if (!_isScanning) ...[
                          const SizedBox(height: 24),
                          ElevatedButton.icon(
                            onPressed: _startScanning,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Escanear de nuevo'),
                          ),
                        ],
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: _devices.length,
                    itemBuilder: (context, index) {
                      final device = _devices[index];
                      return ListTile(
                        leading: const Icon(
                          Icons.bluetooth,
                          color: Colors.blue,
                        ),
                        title: Text(
                          device.name.isNotEmpty
                              ? device.name
                              : 'Dispositivo desconocido',
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                        subtitle: Text(
                          device.address,
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade600,
                          ),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _selectDevice(device),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// Main Screen with BottomNavigationBar
class MainScreen extends StatefulWidget {
  final MeshtasticService meshtasticService;

  const MainScreen({super.key, required this.meshtasticService});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  int _currentIndex = 0;

  MeshtasticService get _service => widget.meshtasticService;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _service.addListener(_onServiceChange);
    _connectToDevice();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _service.removeListener(_onServiceChange);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // La app volvió al primer plano — verificar conexión BLE
      if (!_service.isConnected) {
        debugPrint('📱 [LIFECYCLE] App resumed, reconectando...');
        _service.connectToSavedDevice();
      }
    }
  }

  void _onServiceChange() {
    setState(() {});
  }

  Future<void> _connectToDevice() async {
    await _service.connectToSavedDevice();
  }

  void _navigateToDeviceSelection() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) =>
            DeviceSelectionScreen(meshtasticService: _service),
      ),
    );
  }

  Widget _buildCurrentPage() {
    switch (_currentIndex) {
      case 0:
        return FormScreen(meshtasticService: _service);
      case 1:
        return RequestsScreen(meshtasticService: _service);
      case 2:
        return ChatScreen(meshtasticService: _service);
      case 3:
        return SettingsScreen(
          meshtasticService: _service,
          onDeviceChange: _navigateToDeviceSelection,
          onDisconnect: _navigateToDeviceSelection,
        );
      default:
        return FormScreen(meshtasticService: _service);
    }
  }

  Future<bool> _confirmExit() async {
    final activeCount = _service.activeVisitors.length;
    final pendingCount = _service.pendingRequestsCount;

    final extraInfo = <String>[];
    if (activeCount > 0) {
      extraInfo.add('$activeCount visitante${activeCount == 1 ? '' : 's'} activo${activeCount == 1 ? '' : 's'}');
    }
    if (pendingCount > 0) {
      extraInfo.add('$pendingCount solicitud${pendingCount == 1 ? '' : 'es'} pendiente${pendingCount == 1 ? '' : 's'}');
    }

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('¿Salir de la app?'),
        content: Text(
          extraInfo.isEmpty
              ? 'La app dejará de recibir mensajes mientras esté cerrada.'
              : 'Tienes ${extraInfo.join(' y ')}. '
                  'Los datos quedan guardados, pero la app dejará de recibir mensajes mientras esté cerrada.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Salir'),
          ),
        ],
      ),
    );
    return result == true;
  }

  Future<void> _handlePopAttempt() async {
    // Si no estamos en la pestaña Registro, ir ahí en vez de salir.
    if (_currentIndex != 0) {
      setState(() => _currentIndex = 0);
      return;
    }
    // En Registro: pedir confirmación y luego cerrar la app.
    final shouldExit = await _confirmExit();
    if (shouldExit) {
      await SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final pendingCount = _service.pendingRequestsCount;
    final unreadChat = _service.unreadChatCount;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handlePopAttempt();
      },
      child: Scaffold(
      body: _buildCurrentPage(),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
          if (index == 2) {
            _service.clearUnreadChat();
          }
          setState(() => _currentIndex = index);
        },
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.edit_note_outlined),
            selectedIcon: Icon(Icons.edit_note),
            label: 'Registro',
          ),
          NavigationDestination(
            icon: Badge(
              label: Text('$pendingCount'),
              isLabelVisible: pendingCount > 0,
              child: const Icon(Icons.list_alt_outlined),
            ),
            selectedIcon: Badge(
              label: Text('$pendingCount'),
              isLabelVisible: pendingCount > 0,
              child: const Icon(Icons.list_alt),
            ),
            label: 'Solicitudes',
          ),
          NavigationDestination(
            icon: Badge(
              label: Text('$unreadChat'),
              isLabelVisible: unreadChat > 0,
              child: const Icon(Icons.chat_bubble_outline),
            ),
            selectedIcon: Badge(
              label: Text('$unreadChat'),
              isLabelVisible: unreadChat > 0,
              child: const Icon(Icons.chat_bubble),
            ),
            label: 'Chat',
          ),
          const NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
      ),
    );
  }
}

// Form Screen (previously VisitorRegistrationPage)
class FormScreen extends StatefulWidget {
  final MeshtasticService meshtasticService;

  const FormScreen({super.key, required this.meshtasticService});

  @override
  State<FormScreen> createState() => _FormScreenState();
}

class _FormScreenState extends State<FormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();

  String _selectedReason = 'Motivo 1';
  String _selectedArea = 'Área 1';
  MeshNode? _selectedNode; // Nodo destino seleccionado
  bool _isSending = false;
  bool _waitingResponse = false;
  VisitorResponse? _response;
  StreamSubscription<VisitorResponse>? _responseSubscription;
  // Datos del visitante actual (para agregar a activos al aprobar)
  String? _pendingVisitorName;
  String? _pendingReason;
  String? _pendingArea;

  final List<String> _reasons = ['Motivo 1', 'Motivo 2', 'Motivo 3'];
  final List<String> _areas = ['Área 1', 'Área 2', 'Área 3'];

  MeshtasticService get _service => widget.meshtasticService;

  @override
  void initState() {
    super.initState();
    _selectedNode =
        _service.currentGatewayNode; // Gateway configurado por defecto
    _service.addListener(_onConnectionChange);
    _responseSubscription = _service.responseStream.listen(_onResponse);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _service.removeListener(_onConnectionChange);
    _responseSubscription?.cancel();
    super.dispose();
  }

  void _onConnectionChange() {
    setState(() {});
  }

  void _onResponse(VisitorResponse response) {
    if (_waitingResponse) {
      setState(() {
        _response = response;
        _isSending = false;
        _waitingResponse = false;
      });

      // Si fue aprobado, agregar a visitantes activos y auto-resetear
      if (response.isApproved && _pendingVisitorName != null) {
        _service.addActiveVisitor(
          visitorName: _pendingVisitorName!,
          reason: _pendingReason ?? '',
          area: _pendingArea ?? '',
        );
        // Auto-resetear formulario después de 3 segundos
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) _resetForm();
        });
      }
    }
  }

  void _resetForm() {
    setState(() {
      _nameController.clear();
      _selectedReason = 'Motivo 1';
      _selectedArea = 'Área 1';
      _selectedNode = null;
      _response = null;
      _isSending = false;
      _waitingResponse = false;
      _pendingVisitorName = null;
      _pendingReason = null;
      _pendingArea = null;
    });
  }

  Future<void> _sendRequest() async {
    if (!_formKey.currentState!.validate()) return;

    if (!_service.isConnected) {
      _showSnackBar('No hay conexión con el dispositivo Meshtastic');
      return;
    }

    if (_selectedNode == null) {
      _showSnackBar('Por favor seleccione un nodo destino');
      return;
    }

    setState(() {
      _isSending = true;
      _waitingResponse = true;
      _response = null;
      _pendingVisitorName = _nameController.text.trim();
      _pendingReason = _selectedReason;
      _pendingArea = _selectedArea;
    });

    final success = await _service.sendVisitRequest(
      visitorName: _nameController.text.trim(),
      reason: _selectedReason,
      area: _selectedArea,
      destinationNodeId: _selectedNode!.nodeId,
    );

    if (!success) {
      setState(() {
        _isSending = false;
        _waitingResponse = false;
      });
      _showSnackBar('Error al enviar la solicitud');
    } else {
      setState(() => _isSending = false);
      _showSnackBar('Solicitud enviada a ${_selectedNode!.displayName}');
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _reconnect() async {
    await _service.connectToSavedDevice();
  }

  Widget _buildConnectionStatus() {
    IconData icon;
    Color color;
    String tooltip;

    switch (_service.status) {
      case ConnectionStatus.connected:
        icon = Icons.bluetooth_connected;
        color = Colors.green;
        tooltip = 'Conectado';
        break;
      case ConnectionStatus.connecting:
      case ConnectionStatus.scanning:
        icon = Icons.bluetooth_searching;
        color = Colors.orange;
        tooltip = _service.statusMessage;
        break;
      case ConnectionStatus.error:
        icon = Icons.bluetooth_disabled;
        color = Colors.red;
        tooltip = 'Error';
        break;
      case ConnectionStatus.disconnected:
        icon = Icons.bluetooth;
        color = Colors.grey;
        tooltip = 'Desconectado';
        break;
    }

    return Tooltip(
      message: tooltip,
      child: Icon(icon, color: color, size: 22),
    );
  }

  Widget _buildResponseCard() {
    // Mostrar indicador de espera
    if (_waitingResponse && _response == null) {
      return Card(
        elevation: 4,
        color: Colors.blue.shade50,
        child: const Padding(
          padding: EdgeInsets.all(24.0),
          child: Column(
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text(
                'Esperando respuesta...',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
              ),
              SizedBox(height: 4),
              Text(
                'La solicitud fue enviada al supervisor',
                style: TextStyle(fontSize: 14, color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }

    // No hay respuesta
    if (_response == null) return const SizedBox.shrink();

    // Determinar colores y iconos según status
    final isApproved = _response!.isApproved;
    final isDenied = _response!.isDenied;

    final Color bgColor = isApproved
        ? Colors.green.shade50
        : isDenied
        ? Colors.red.shade50
        : Colors.orange.shade50;

    final Color iconColor = isApproved
        ? Colors.green
        : isDenied
        ? Colors.red
        : Colors.orange;

    final IconData icon = isApproved
        ? Icons.check_circle
        : isDenied
        ? Icons.cancel
        : Icons.pending;

    final String statusText = isApproved
        ? 'APROBADO'
        : isDenied
        ? 'NEGADO'
        : 'PENDIENTE';

    return Card(
      elevation: 4,
      color: bgColor,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Icon(icon, color: iconColor, size: 56),
            const SizedBox(height: 12),
            Text(
              statusText,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: iconColor,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Por: ${_response!.supervisorName}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
            ),
            if (_response!.comment != null &&
                _response!.comment!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white70,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.comment, size: 18, color: Colors.grey),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _response!.comment!,
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (isApproved) ...[
              const SizedBox(height: 8),
              Text(
                'El visitante aparece en la lista de abajo',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
              ),
            ],
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _resetForm,
              icon: const Icon(Icons.add),
              label: const Text('Nueva Solicitud'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _registerVisitorExit(ActiveVisitor visitor) async {
    final success = await _service.sendSalidaToGateway(
      visitorName: visitor.visitorName,
    );
    if (success) {
      _service.markVisitorExited(visitor.visitorName);
      _showSnackBar('Salida registrada: ${visitor.visitorName}');
    } else {
      _showSnackBar('Error al registrar salida');
    }
  }

  Widget _buildActiveVisitors() {
    final visitors = _service.allVisitors;
    if (visitors.isEmpty) return const SizedBox.shrink();

    // Mostrar activos primero, luego los que ya salieron (hoy)
    final active = visitors.where((v) => !v.hasExited).toList();
    final exited = visitors.where((v) => v.hasExited).toList();
    final sorted = [...active, ...exited];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 32),
        Row(
          children: [
            const Icon(Icons.people, size: 20),
            const SizedBox(width: 8),
            Text(
              'Visitantes (${active.length} activos)',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ...sorted.map(
          (visitor) => Card(
            elevation: 2,
            color: visitor.hasExited
                ? Colors.grey.shade100
                : Colors.green.shade50,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    visitor.hasExited ? Icons.logout : Icons.person,
                    color: visitor.hasExited ? Colors.grey : Colors.green,
                    size: 28,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          visitor.visitorName,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                            decoration: visitor.hasExited
                                ? TextDecoration.lineThrough
                                : null,
                          ),
                        ),
                        Text(
                          '${visitor.area} — Entrada: ${visitor.formattedEntryTime}',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade700,
                          ),
                        ),
                        if (visitor.hasExited)
                          Text(
                            'Salida: ${visitor.formattedExitTime}',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.blue.shade700,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (!visitor.hasExited)
                    ElevatedButton.icon(
                      onPressed: () => _registerVisitorExit(visitor),
                      icon: const Icon(Icons.logout, size: 18),
                      label: const Text('Salida'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Registro de Visitantes',
              style: TextStyle(fontSize: 18),
            ),
            if (_service.connectedDeviceName != null)
              Text(
                _service.connectedDeviceName!,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.normal,
                ),
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16.0),
            child: _buildConnectionStatus(),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_service.status == ConnectionStatus.scanning ||
                  _service.status == ConnectionStatus.connecting)
                const Padding(
                  padding: EdgeInsets.only(bottom: 16.0),
                  child: LinearProgressIndicator(),
                ),

              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Nombre del Visitante',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.person),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Por favor ingrese el nombre del visitante';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              DropdownButtonFormField<String>(
                value: _selectedReason,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Motivo de Visita',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.description),
                ),
                items: _reasons.map((reason) {
                  return DropdownMenuItem(value: reason, child: Text(reason));
                }).toList(),
                onChanged: (value) {
                  setState(() => _selectedReason = value!);
                },
              ),
              const SizedBox(height: 16),

              DropdownButtonFormField<String>(
                value: _selectedArea,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Área a Visitar',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.location_on),
                ),
                items: _areas.map((area) {
                  return DropdownMenuItem(value: area, child: Text(area));
                }).toList(),
                onChanged: (value) {
                  setState(() => _selectedArea = value!);
                },
              ),
              const SizedBox(height: 16),

              // Selector de nodo destino
              DropdownButtonFormField<MeshNode>(
                value: _selectedNode,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Enviar a (Nodo Destino)',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.router),
                ),
                hint: const Text('Seleccione un nodo'),
                items: _service.onlineNodes.map((node) {
                  return DropdownMenuItem(
                    value: node,
                    child: Text(
                      '${node.displayName} (${node.shortId})',
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                }).toList(),
                onChanged: (value) {
                  setState(() => _selectedNode = value);
                },
                validator: (value) {
                  if (value == null) {
                    return 'Por favor seleccione un nodo destino';
                  }
                  return null;
                },
              ),
              if (_service.onlineNodes.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: Text(
                    'No hay nodos disponibles. Espere a recibir mensajes de otros nodos.',
                    style: TextStyle(
                      color: Colors.orange.shade700,
                      fontSize: 12,
                    ),
                  ),
                ),
              const SizedBox(height: 24),

              ElevatedButton.icon(
                onPressed: _isSending || !_service.isConnected
                    ? null
                    : _sendRequest,
                icon: _isSending
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send),
                label: Text(_isSending ? 'Enviando...' : 'Enviar Solicitud'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Colors.white,
                ),
              ),
              const SizedBox(height: 24),

              _buildResponseCard(),

              _buildActiveVisitors(),

              if (_service.status == ConnectionStatus.error ||
                  _service.status == ConnectionStatus.disconnected)
                Padding(
                  padding: const EdgeInsets.only(top: 16.0),
                  child: OutlinedButton.icon(
                    onPressed: _reconnect,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Reconectar'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
