# Referencia: Pantalla de Settings (Configuración)

> Documento para replicar el patrón de settings en otra app Flutter.
> Basado en `sirius_porteria`.

---

## 1. Arquitectura General

La pantalla de Settings es un `StatefulWidget` que recibe:

```dart
class SettingsScreen extends StatefulWidget {
  final MeshtasticService meshtasticService;  // Servicio central (ChangeNotifier)
  final VoidCallback onDeviceChange;           // Callback para cambiar dispositivo
  final VoidCallback onDisconnect;             // Callback para desconectar
}
```

**Patrón clave**: El servicio es un `ChangeNotifier`. La pantalla se suscribe a cambios con `addListener` y hace `setState` para re-renderizar automáticamente cuando cambia el estado del servicio.

```dart
@override
void initState() {
  super.initState();
  _service.addListener(_onServiceChange);  // Escuchar cambios
  _loadSavedRegion();                       // Cargar preferencias guardadas
  _loadSavedGateway();
}

void _onServiceChange() => setState(() {});  // Re-render al cambiar estado
```

---

## 2. Persistencia con SharedPreferences

Se usan constantes como keys para guardar/leer configuración local:

```dart
const String _savedDeviceAddressKey = 'saved_device_address';
const String _savedDeviceNameKey = 'saved_device_name';
const String _loraRegionKey = 'lora_region';
const String _gatewayNodeIdKey = 'gateway_node_id';
```

### Patrón de lectura/escritura

```dart
// Leer
Future<LoraRegion> getSavedLoraRegion() async {
  final prefs = await SharedPreferences.getInstance();
  final code = prefs.getString(_loraRegionKey);
  return code != null ? LoraRegion.fromCode(code) : LoraRegion.unset;
}

// Escribir
Future<void> saveLoraRegion(LoraRegion region) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_loraRegionKey, region.code);
}

// Borrar (para disconnect)
Future<void> clearSavedDevice() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_savedDeviceAddressKey);
  await prefs.remove(_savedDeviceNameKey);
}
```

**Dependencia**: `shared_preferences: ^2.2.2`

---

## 3. Secciones de la Pantalla

La pantalla usa un `SingleChildScrollView` con `Card`s apilados verticalmente.

### 3.1 Nodo Conectado (Info del dispositivo BLE)

Muestra información del dispositivo Bluetooth conectado:

| Campo | Fuente |
|---|---|
| Nombre | `_service.connectedDeviceName` |
| MAC Address | `_service.connectedDeviceMac` |
| Estado | `_service.isConnected` (verde/rojo) |
| Batería | Widget `BatteryIndicator` con `_service.connectedNodeBatteryLevel` |

Incluye botón "Desconectar" con **diálogo de confirmación**:

```dart
Future<void> _disconnectDevice() async {
  final confirm = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Desconectar nodo'),
      content: const Text('¿Estás seguro...?'),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text('Cancelar')),
        TextButton(onPressed: () => Navigator.of(context).pop(true), child: Text('Desconectar')),
      ],
    ),
  );
  if (confirm == true) {
    await _service.disconnectAndClear();
    widget.onDisconnect();  // Navega de vuelta a selección de dispositivo
  }
}
```

### 3.2 Gateway (Selector de nodo destino)

Un `DropdownButtonFormField<MeshNode>` que lista los nodos online de la red mesh.
Al seleccionar, se guarda inmediatamente con `_service.saveGatewayNodeId(value.nodeId)`.

```dart
DropdownButtonFormField<MeshNode>(
  value: selectedNode,
  items: nodes.map((node) => DropdownMenuItem(
    value: node,
    child: Text('${node.displayName} (${node.shortId})'),
  )).toList(),
  onChanged: (value) {
    setState(() => _selectedGatewayNodeId = value.nodeId);
    _service.saveGatewayNodeId(value.nodeId);  // Persistir inmediatamente
  },
)
```

### 3.3 Configuración LoRa (Región de radio)

Un `DropdownButtonFormField<LoraRegion>` + botón "Aplicar Configuración".

**Enum con display names**:

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

**Flujo de aplicar**:
1. Guarda localmente siempre (`saveLoraRegion`)
2. Si hay conexión, envía al dispositivo BLE
3. Si no hay conexión, muestra mensaje "Se aplicará al conectar"

```dart
Future<void> _applyConfiguration() async {
  setState(() => _isApplyingConfig = true);
  final success = await _service.setLoraRegion(_selectedRegion);
  setState(() => _isApplyingConfig = false);

  // SnackBar con feedback visual
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(success ? 'Configuración aplicada' : 'Error'),
      backgroundColor: success ? Colors.green : Colors.red,
    ),
  );
}
```

**Loading state en botón**:

```dart
ElevatedButton.icon(
  onPressed: !_isApplyingConfig ? _applyConfiguration : null,
  icon: _isApplyingConfig
    ? SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
    : Icon(Icons.check),
  label: Text(_isApplyingConfig ? 'Aplicando...' : 'Aplicar Configuración'),
)
```

### 3.4 Acciones

Botón "Cambiar Nodo" que llama `widget.onDeviceChange()` para navegar a la pantalla de escaneo BLE.

---

## 4. Widget BatteryIndicator (Reutilizable)

Widget independiente que muestra batería con icono + porcentaje:

```dart
class BatteryIndicator extends StatelessWidget {
  final int? batteryLevel;     // null = desconocido, >100 = USB
  final double? voltage;
  final double iconSize;
  final bool showPercentage;
}
```

| Nivel | Icono | Color |
|---|---|---|
| null | `battery_unknown` | gris |
| >100 | `power` (USB) | azul |
| >75 | `battery_full` | verde |
| >50 | `battery_5_bar` | verde |
| >25 | `battery_3_bar` | naranja |
| <=25 | `battery_1_bar` | rojo |

---

## 5. Navegación y Flujo de la App

```
StartupScreen
  ├─ Si hay dispositivo guardado → MainScreen
  └─ Si no → DeviceSelectionScreen

MainScreen (BottomNavigationBar con 4 tabs)
  ├─ Registro (FormScreen)
  ├─ Solicitudes (RequestsScreen)
  ├─ Chat (ChatScreen)
  └─ Settings (SettingsScreen)
        ├─ "Cambiar Nodo" → DeviceSelectionScreen
        └─ "Desconectar" → DeviceSelectionScreen
```

### Auto-reconexión

La app detecta cuando vuelve al primer plano y reconecta automáticamente:

```dart
class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_service.isConnected) {
      _service.connectToSavedDevice();
    }
  }
}
```

---

## 6. Permisos BLE (Android/iOS)

Manejo diferenciado por plataforma antes de escanear:

**Android**: `bluetoothScan`, `bluetoothConnect`, `locationWhenInUse`, `bluetooth` (legacy)
**iOS**: solo `bluetooth`

Si se deniegan, muestra banner rojo con botones "Abrir Configuración" y "Reintentar".

**Dependencia**: `permission_handler: ^12.0.1`

---

## 7. Patrones UI Importantes

### Cards como secciones

Cada sección es un `Card(elevation: 2)` con:
- Header: `Row` con icono + título bold
- `Divider()`
- Contenido

### Feedback con SnackBar

Siempre mostrar resultado de acciones:

```dart
ScaffoldMessenger.of(context).showSnackBar(
  SnackBar(
    content: Text(message),
    backgroundColor: success ? Colors.green : Colors.red,
  ),
);
```

### Badges en NavigationBar

Contadores en los tabs de Solicitudes y Chat:

```dart
NavigationDestination(
  icon: Badge(
    label: Text('$count'),
    isLabelVisible: count > 0,
    child: Icon(Icons.chat_bubble_outline),
  ),
  label: 'Chat',
)
```

### Estado del servicio como ChangeNotifier

Todo el estado vive en un servicio central que extiende `ChangeNotifier`. Las pantallas se suscriben y reaccionan:

```dart
// En el servicio:
class MeshtasticService extends ChangeNotifier {
  void _updateStatus(ConnectionStatus s) {
    _status = s;
    notifyListeners();
  }
}

// En cualquier pantalla:
_service.addListener(() => setState(() {}));
```
