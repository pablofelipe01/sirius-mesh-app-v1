import 'dart:async';
import 'package:flutter/material.dart';
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
          builder: (context) => MainScreen(
            meshtasticService: _meshtasticService,
          ),
        ),
      );
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => DeviceSelectionScreen(
            meshtasticService: _meshtasticService,
          ),
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

  const DeviceSelectionScreen({
    super.key,
    required this.meshtasticService,
  });

  @override
  State<DeviceSelectionScreen> createState() => _DeviceSelectionScreenState();
}

class _DeviceSelectionScreenState extends State<DeviceSelectionScreen> {
  final List<ScannedDevice> _devices = [];
  bool _isScanning = false;
  StreamSubscription<ScannedDevice>? _scanSubscription;

  @override
  void initState() {
    super.initState();
    _startScanning();
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    super.dispose();
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
        builder: (context) => MainScreen(
          meshtasticService: widget.meshtasticService,
        ),
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
          if (_isScanning)
            const LinearProgressIndicator(),
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
          Expanded(
            child: _devices.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _isScanning ? Icons.bluetooth_searching : Icons.bluetooth_disabled,
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
                        leading: const Icon(Icons.bluetooth, color: Colors.blue),
                        title: Text(
                          device.name.isNotEmpty ? device.name : 'Dispositivo desconocido',
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

  const MainScreen({
    super.key,
    required this.meshtasticService,
  });

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;

  MeshtasticService get _service => widget.meshtasticService;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onServiceChange);
    _connectToDevice();
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChange);
    super.dispose();
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
        builder: (context) => DeviceSelectionScreen(
          meshtasticService: _service,
        ),
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

  @override
  Widget build(BuildContext context) {
    final pendingCount = _service.pendingRequestsCount;

    return Scaffold(
      body: _buildCurrentPage(),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (index) {
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
          const NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: 'Chat',
          ),
          const NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

// Form Screen (previously VisitorRegistrationPage)
class FormScreen extends StatefulWidget {
  final MeshtasticService meshtasticService;

  const FormScreen({
    super.key,
    required this.meshtasticService,
  });

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

  final List<String> _reasons = ['Motivo 1', 'Motivo 2', 'Motivo 3'];
  final List<String> _areas = ['Área 1', 'Área 2', 'Área 3'];

  MeshtasticService get _service => widget.meshtasticService;

  @override
  void initState() {
    super.initState();
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _reconnect() async {
    await _service.connectToSavedDevice();
  }

  Widget _buildConnectionStatus() {
    IconData icon;
    Color color;

    switch (_service.status) {
      case ConnectionStatus.connected:
        icon = Icons.bluetooth_connected;
        color = Colors.green;
        break;
      case ConnectionStatus.connecting:
      case ConnectionStatus.scanning:
        icon = Icons.bluetooth_searching;
        color = Colors.orange;
        break;
      case ConnectionStatus.error:
        icon = Icons.bluetooth_disabled;
        color = Colors.red;
        break;
      case ConnectionStatus.disconnected:
        icon = Icons.bluetooth;
        color = Colors.grey;
        break;
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            _service.statusMessage,
            style: TextStyle(color: color, fontSize: 12),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
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
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
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
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (_response!.comment != null && _response!.comment!.isNotEmpty) ...[
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Registro de Visitantes'),
            if (_service.connectedDeviceName != null)
              Text(
                _service.connectedDeviceName!,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.normal),
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
                initialValue: _selectedReason,
                decoration: const InputDecoration(
                  labelText: 'Motivo de Visita',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.description),
                ),
                items: _reasons.map((reason) {
                  return DropdownMenuItem(
                    value: reason,
                    child: Text(reason),
                  );
                }).toList(),
                onChanged: (value) {
                  setState(() => _selectedReason = value!);
                },
              ),
              const SizedBox(height: 16),

              DropdownButtonFormField<String>(
                initialValue: _selectedArea,
                decoration: const InputDecoration(
                  labelText: 'Área a Visitar',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.location_on),
                ),
                items: _areas.map((area) {
                  return DropdownMenuItem(
                    value: area,
                    child: Text(area),
                  );
                }).toList(),
                onChanged: (value) {
                  setState(() => _selectedArea = value!);
                },
              ),
              const SizedBox(height: 16),

              // Selector de nodo destino
              DropdownButtonFormField<MeshNode>(
                initialValue: _selectedNode,
                decoration: const InputDecoration(
                  labelText: 'Enviar a (Nodo Destino)',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.router),
                ),
                hint: const Text('Seleccione un nodo'),
                items: _service.onlineNodes.map((node) {
                  return DropdownMenuItem(
                    value: node,
                    child: Text('${node.displayName} (${node.shortId})'),
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
