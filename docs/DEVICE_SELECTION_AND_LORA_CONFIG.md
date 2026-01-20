# Seleccion de Dispositivo y Configuracion LoRa

Este documento explica como se implemento el sistema de seleccion de dispositivos Meshtastic via Bluetooth y la configuracion de parametros LoRa en la aplicacion Sirius Porteria.

## Arquitectura General

```
┌─────────────────────┐
│   StartupScreen     │  ← Punto de entrada
└──────────┬──────────┘
           │
           ▼
    ¿Hay dispositivo
       guardado?
      /         \
    SI           NO
     │            │
     ▼            ▼
┌──────────┐  ┌─────────────────────┐
│MainScreen│  │DeviceSelectionScreen│
└──────────┘  └─────────────────────┘
     │
     └──► SettingsScreen (configuracion LoRa)
```

---

## 1. Flujo de Seleccion de Dispositivo

### 1.1 StartupScreen (Pantalla de Inicio)

Archivo: `lib/main.dart` (lineas 33-94)

Esta pantalla verifica si hay un dispositivo guardado previamente:

```dart
class _StartupScreenState extends State<StartupScreen> {
  final _meshtasticService = MeshtasticService();

  @override
  void initState() {
    super.initState();
    _checkSavedDevice();
  }

  Future<void> _checkSavedDevice() async {
    final savedAddress = await _meshtasticService.getSavedDeviceAddress();

    if (savedAddress != null) {
      // Hay dispositivo guardado -> ir a MainScreen
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => MainScreen(meshtasticService: _meshtasticService),
        ),
      );
    } else {
      // No hay dispositivo -> ir a seleccion
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => DeviceSelectionScreen(meshtasticService: _meshtasticService),
        ),
      );
    }
  }
}
```

### 1.2 DeviceSelectionScreen (Escaneo BLE)

Archivo: `lib/main.dart` (lineas 96-260)

Esta pantalla escanea dispositivos Meshtastic via Bluetooth:

```dart
class _DeviceSelectionScreenState extends State<DeviceSelectionScreen> {
  final List<ScannedDevice> _devices = [];
  bool _isScanning = false;
  StreamSubscription<ScannedDevice>? _scanSubscription;

  void _startScanning() {
    setState(() {
      _devices.clear();
      _isScanning = true;
    });

    // Escuchar el stream de dispositivos encontrados
    _scanSubscription = widget.meshtasticService.scanDevices().listen(
      (device) {
        setState(() {
          final exists = _devices.any((d) => d.address == device.address);
          if (!exists) {
            _devices.add(device);
          }
        });
      },
      onDone: () => setState(() => _isScanning = false),
    );
  }

  Future<void> _selectDevice(ScannedDevice device) async {
    await widget.meshtasticService.connectToDevice(device);

    // Navegar a la pantalla principal
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) => MainScreen(meshtasticService: widget.meshtasticService),
      ),
    );
  }
}
```

**Caracteristicas de la UI:**
- Muestra icono de Bluetooth con estado de escaneo
- Lista de dispositivos encontrados con nombre y MAC address
- Boton de refresh para re-escanear
- Indicador de progreso durante el escaneo

---

## 2. MeshtasticService - Logica de Conexion

Archivo: `lib/services/meshtastic_service.dart`

### 2.1 Modelo ScannedDevice

```dart
class ScannedDevice {
  final String name;        // Nombre del dispositivo BLE
  final String address;     // MAC address
  final dynamic rawDevice;  // Objeto nativo del paquete meshtastic_flutter

  ScannedDevice({
    required this.name,
    required this.address,
    required this.rawDevice,
  });
}
```

### 2.2 Estados de Conexion

```dart
enum ConnectionStatus {
  disconnected,  // Sin conexion
  scanning,      // Escaneando dispositivos
  connecting,    // Conectando a un dispositivo
  connected,     // Conectado exitosamente
  error,         // Error de conexion
}
```

### 2.3 Escaneo de Dispositivos

```dart
Stream<ScannedDevice> scanDevices() async* {
  try {
    _updateStatus(ConnectionStatus.scanning, 'Buscando dispositivos...');
    await _ensureClientInitialized();

    await for (final device in _client!.scanForDevices()) {
      final scannedDevice = ScannedDevice(
        name: device.platformName,
        address: device.remoteId.toString(),
        rawDevice: device,
      );
      yield scannedDevice;
    }
  } catch (e) {
    _updateStatus(ConnectionStatus.error, 'Error escaneando: ${e.toString()}');
  }
}
```

### 2.4 Conexion a Dispositivo

```dart
Future<void> connectToDevice(ScannedDevice device) async {
  try {
    _updateStatus(ConnectionStatus.connecting, 'Conectando a ${device.name}...');
    await _ensureClientInitialized();

    // Escuchar cambios de estado de conexion
    _connectionSubscription = _client!.connectionStream.listen((status) {
      final stateStr = status.state.toString().toLowerCase();
      if (stateStr.contains('connected') && !stateStr.contains('dis')) {
        _updateStatus(ConnectionStatus.connected, 'Conectado');
        _applyInitialConfig();  // Aplicar config LoRa guardada
      } else if (stateStr.contains('disconnect')) {
        _updateStatus(ConnectionStatus.disconnected, 'Desconectado');
      }
    });

    // Escuchar paquetes entrantes
    _packetSubscription = _client!.packetStream.listen(_handlePacket);

    // Conectar al dispositivo
    await _client!.connectToDevice(device.rawDevice);

    // Guardar informacion del dispositivo
    _connectedDeviceName = device.name;
    _connectedDeviceMac = device.address;
    await saveDeviceInfo(device.address, device.name);
  } catch (e) {
    _updateStatus(ConnectionStatus.error, 'Error: ${e.toString()}');
  }
}
```

### 2.5 Persistencia del Dispositivo

Se utiliza `SharedPreferences` para guardar la informacion del dispositivo:

```dart
const String _savedDeviceAddressKey = 'saved_device_address';
const String _savedDeviceNameKey = 'saved_device_name';

Future<String?> getSavedDeviceAddress() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_savedDeviceAddressKey);
}

Future<void> saveDeviceInfo(String address, String name) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_savedDeviceAddressKey, address);
  await prefs.setString(_savedDeviceNameKey, name);
}

Future<void> clearSavedDevice() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_savedDeviceAddressKey);
  await prefs.remove(_savedDeviceNameKey);
}
```

---

## 3. Configuracion LoRa

### 3.1 Regiones LoRa Soportadas

```dart
enum LoraRegion {
  unset('UNSET', 'Sin configurar'),
  us('US', '915 MHz'),
  eu433('EU_433', '433 MHz'),
  eu868('EU_868', '868 MHz');

  final String code;
  final String frequency;

  const LoraRegion(this.code, this.frequency);

  String get displayName => '$code ($frequency)';
}
```

### 3.2 SettingsScreen (UI de Configuracion)

Archivo: `lib/screens/settings_screen.dart`

La pantalla de configuracion tiene tres secciones:

#### Seccion 1: Informacion del Nodo Conectado
```dart
Widget _buildNodeInfoSection() {
  return Card(
    child: Column(
      children: [
        _buildInfoRow('Nombre', deviceName),
        _buildInfoRow('MAC Address', deviceMac),
        _buildInfoRow('Estado', isConnected ? 'Conectado' : 'Desconectado'),
        OutlinedButton.icon(
          onPressed: _disconnectDevice,
          icon: Icon(Icons.bluetooth_disabled),
          label: Text('Desconectar'),
        ),
      ],
    ),
  );
}
```

#### Seccion 2: Configuracion LoRa
```dart
Widget _buildLoraConfigSection() {
  return Card(
    child: Column(
      children: [
        DropdownButtonFormField<LoraRegion>(
          initialValue: _selectedRegion,
          items: LoraRegion.values.map((region) {
            return DropdownMenuItem(
              value: region,
              child: Text(region.displayName),
            );
          }).toList(),
          onChanged: (value) => setState(() => _selectedRegion = value!),
        ),
        ElevatedButton.icon(
          onPressed: _service.isConnected ? _applyConfiguration : null,
          label: Text('Aplicar Configuracion'),
        ),
      ],
    ),
  );
}
```

#### Seccion 3: Acciones
```dart
Widget _buildActionsSection() {
  return Card(
    child: ElevatedButton.icon(
      onPressed: _changeDevice,
      icon: Icon(Icons.bluetooth_searching),
      label: Text('Cambiar Nodo'),
    ),
  );
}
```

### 3.3 Aplicar Configuracion LoRa

```dart
Future<bool> setLoraRegion(LoraRegion region) async {
  if (!isConnected || _client == null) {
    return false;
  }

  try {
    // Enviar comando de configuracion al nodo
    final configMessage = 'CONFIG|LORA_REGION|${region.code}';
    await _client!.sendTextMessage(configMessage, channel: 0);

    // Guardar configuracion localmente
    await saveLoraRegion(region);
    return true;
  } catch (e) {
    debugPrint('Error configurando region LoRa: $e');
    return false;
  }
}
```

### 3.4 Persistencia de Region LoRa

```dart
const String _loraRegionKey = 'lora_region';

Future<LoraRegion> getSavedLoraRegion() async {
  final prefs = await SharedPreferences.getInstance();
  final code = prefs.getString(_loraRegionKey);
  return code != null ? LoraRegion.fromCode(code) : LoraRegion.unset;
}

Future<void> saveLoraRegion(LoraRegion region) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_loraRegionKey, region.code);
}
```

### 3.5 Auto-aplicar Configuracion al Conectar

Cuando el dispositivo se conecta, se aplica automaticamente la region guardada:

```dart
Future<void> _applyInitialConfig() async {
  final savedRegion = await getSavedLoraRegion();
  if (savedRegion != LoraRegion.unset) {
    await setLoraRegion(savedRegion);
  }
}
```

---

## 4. Diagrama de Flujo Completo

```
    INICIO APP
        │
        ▼
┌───────────────────┐
│  StartupScreen    │
│  (Cargando...)    │
└────────┬──────────┘
         │
         ▼
   SharedPreferences
   ¿saved_device_address?
        /     \
      SI       NO
       │        │
       │        ▼
       │   ┌──────────────────────┐
       │   │DeviceSelectionScreen │
       │   │                      │
       │   │ 1. scanDevices()     │
       │   │ 2. Lista dispositivos│
       │   │ 3. Usuario selecciona│
       │   │ 4. connectToDevice() │
       │   │ 5. saveDeviceInfo()  │
       │   └──────────┬───────────┘
       │              │
       ▼              ▼
┌──────────────────────┐
│     MainScreen       │
│                      │
│ ┌──────────────────┐ │
│ │ Tabs:            │ │
│ │ - Registro       │ │
│ │ - Solicitudes    │ │
│ │ - Chat           │ │
│ │ - Settings ──────┼─┼──┐
│ └──────────────────┘ │  │
└──────────────────────┘  │
                          ▼
              ┌───────────────────┐
              │  SettingsScreen   │
              │                   │
              │ - Info del nodo   │
              │ - Config LoRa     │
              │ - Cambiar nodo    │
              │ - Desconectar     │
              └───────────────────┘
```

---

## 5. Dependencias Utilizadas

```yaml
dependencies:
  flutter:
    sdk: flutter
  meshtastic_flutter: ^0.0.3    # Comunicacion con nodos Meshtastic
  shared_preferences: ^2.0.0     # Persistencia local
```

---

## 6. Notas Importantes

1. **Permisos Bluetooth**: La app requiere permisos de Bluetooth en Android/iOS para escanear y conectar dispositivos.

2. **Reconexion Automatica**: Si hay un dispositivo guardado, la app intenta conectarse automaticamente al iniciar.

3. **Manejo de Errores**: El servicio maneja errores de conexion y actualiza el estado de la UI via `ChangeNotifier`.

4. **Region LoRa**: La configuracion de region se aplica automaticamente al conectar un dispositivo.

5. **Desconexion**: Al desconectar, se puede optar por borrar el dispositivo guardado y volver a la pantalla de seleccion.
