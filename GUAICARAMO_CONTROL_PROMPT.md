# Guaicaramo Control — Prompt para construir la app desde cero

> Este documento es un prompt para Claude Code: contiene la arquitectura, modelos,
> pantallas, protocolo de mensajes y plan de implementación de una app Flutter llamada
> **`guaicaramo_control`** que se comunica con una red mesh Meshtastic (LoRa + BLE).
>
> La app es heredera de `sirius_porteria` (app de portería existente) — reutiliza la
> base BLE/mesh/chat pero introduce un mapa con nodos GPS y un flujo de recepción de
> vehículos basado en consultas al gateway.

---

## 1. Contexto del proyecto

Plantación **Guaicaramo** — 15.000 hectáreas, sin conectividad celular ni WiFi en
campo. La comunicación entre personal y porterías se hace por una red mesh
**Meshtastic** (radios LoRa conectados por Bluetooth a celulares Android/iOS).

La app cumple tres funciones:

1. **Chat mesh** — DMs y canales broadcast entre nodos de la red.
2. **Mapa de nodos** — visualización en tiempo real de la ubicación GPS de cada nodo
   con tracks de la sesión. Tap en un nodo abre DM con ese nodo.
3. **Recepción de vehículos** — el portero registra CC + placa, consulta al gateway
   (que tiene la lista de placas aprobadas en Airtable), y según la respuesta deja
   pasar al vehículo o solicita aprobación manual a un supervisor remoto.

---

## 2. Stack tecnológico

| Componente | Tecnología | Notas |
|---|---|---|
| App móvil | Flutter (Dart) | Android + iOS |
| SDK BLE/mesh | `meshtastic_flutter` (fork local en `packages/`) | Reutilizar el fork de `sirius_porteria` |
| Mapa | `flutter_map` + tiles MBTiles pre-empacados | OpenStreetMap, offline real |
| State | `ChangeNotifier` + `Stream`s | Mismo patrón que `sirius_porteria` |
| Persistencia | `shared_preferences` (JSON serializado) | |
| Permisos BLE | `permission_handler` | Android 12+ requiere SCAN/CONNECT |
| Gateway | Python en Raspberry Pi | Reutiliza el del proyecto actual + handler `CONSULTA` |
| Base de datos | Airtable (API REST desde el Pi) | Tabla `Placas` para autorización + tabla `Registros` para histórico |

### Dependencias mínimas (`pubspec.yaml`)

```yaml
dependencies:
  flutter:
    sdk: flutter
  meshtastic_flutter:
    path: packages/meshtastic_flutter   # Copiar del fork existente
  flutter_map: ^7.0.0                   # Mapa
  flutter_map_mbtiles: ^2.0.0           # Lectura de MBTiles offline
  latlong2: ^0.9.1                      # Tipo LatLng para flutter_map
  shared_preferences: ^2.2.2
  permission_handler: ^12.0.1
  cupertino_icons: ^1.0.8
```

---

## 3. Estructura del proyecto

```
guaicaramo_control/
├── lib/
│   ├── main.dart                          # Entry + Startup + DeviceSelection + MainScreen
│   ├── models/
│   │   └── data_models.dart               # Todos los modelos
│   ├── services/
│   │   └── meshtastic_service.dart        # BLE + mesh + estado + persistencia + GPS
│   ├── screens/
│   │   ├── recepcion_screen.dart          # CC + Placa + consulta gateway
│   │   ├── requests_screen.dart           # Lista de solicitudes (supervisor)
│   │   ├── chat_screen.dart               # Chat (DMs + canales)
│   │   ├── map_screen.dart                # Mapa con nodos GPS — NUEVA
│   │   └── settings_screen.dart           # Nodo, gateway, región LoRa, borrar datos
│   └── widgets/
│       ├── battery_indicator.dart         # Reutilizar
│       ├── delivery_indicator.dart        # Reutilizar
│       └── node_marker.dart               # Marker custom para mapa
├── assets/
│   └── maps/
│       └── guaicaramo.mbtiles             # Tiles OSM pre-descargados
├── packages/
│   └── meshtastic_flutter/                # Fork local del SDK
├── gateway/
│   └── gateway.py                         # Script Python en el Pi
└── pubspec.yaml
```

---

## 4. Modelos de datos (`lib/models/data_models.dart`)

```dart
enum DeliveryStatus { sending, delivered, failed, none }

class ChatMessage {
  final String id;
  final String messageText;
  final int fromNodeId;
  final String fromNodeName;
  final DateTime timestamp;
  final int channel;
  final int? toNodeId;
  final bool isDirectMessage;
  final bool isMine;
  DeliveryStatus deliveryStatus;
  // ... toJson/fromJson para persistencia
}

class MeshNode {
  final int nodeId;
  final String nodeName;
  final bool isOnline;
  final DateTime? lastSeen;
  final int? batteryLevel;       // 0-100; >100 = USB powered
  final double? voltage;
  final double? latitude;        // NUEVO
  final double? longitude;       // NUEVO
  final int? altitude;           // NUEVO (opcional)
  final DateTime? positionTime;  // NUEVO — cuándo se recibió la última posición
  // ...
  bool get hasPosition => latitude != null && longitude != null;
}

class NodePositionPoint {       // NUEVO — para el track de sesión
  final double latitude;
  final double longitude;
  final DateTime timestamp;
  NodePositionPoint(this.latitude, this.longitude, this.timestamp);
}

class VehicleEntry {            // Reemplaza ActiveVisitor
  final String cedula;
  final String placa;
  final DateTime entryTime;
  DateTime? exitTime;
  String? approvedBy;           // 'GATEWAY' (lista Airtable) o nombre del supervisor
  bool get hasExited => exitTime != null;
  // ... toJson/fromJson
}

class VehicleRequest {          // Solicitud de aprobación manual (cuando placa NO está)
  final int requestId;
  final String cedula;
  final String placa;
  final int fromNodeId;
  final String fromNodeName;
  final DateTime timestamp;
  bool isResponded;
  String? responseStatus;       // APROBADO, NEGADO, PENDIENTE
  String? supervisorName;
  String? comment;
  // ... toJson/fromJson
}

enum PlateCheckStatus { approved, notApproved, timeout, error }

class PlateCheckResult {        // Respuesta de la consulta al gateway
  final PlateCheckStatus status;
  final String? driverName;     // Si gateway envía nombre asociado
  final String? note;
}

class ChatDestination {
  // Idéntico a sirius_porteria: primaryChannel (0), supervisorsChannel (1), o DM a nodo
}
```

---

## 5. `MeshtasticService` — responsabilidades

Esta clase concentra TODO: BLE, packet handling, estado de la app y persistencia. Es
un `ChangeNotifier` y expone `Stream`s para eventos en tiempo real.

### Estado interno

```dart
class MeshtasticService extends ChangeNotifier {
  MeshtasticClient? _client;
  ConnectionStatus _status = ConnectionStatus.disconnected;

  // Cache de nodos conocidos (auto-detectados de la mesh)
  final Map<int, MeshNode> _knownNodes = {};

  // Track de posiciones por nodo (solo sesión actual, NO persistente)
  final Map<int, List<NodePositionPoint>> _sessionTracks = {};

  // Datos persistentes
  final List<ChatMessage> _messageHistory = [];
  final List<VehicleRequest> _vehicleRequests = [];
  final List<VehicleEntry> _vehicleEntries = [];

  // Auto-reconexión + keepalive (igual que sirius_porteria)
  bool _autoReconnectEnabled = false;
  Timer? _keepaliveTimer;

  // Dedupe de paquetes — USAR Queue<int>, no Set (bug de sirius_porteria)
  final Queue<int> _processedPacketIds = Queue<int>();
  final Set<int> _processedPacketSet = {};

  // Pendientes de consulta de placa: requestId -> Completer
  final Map<String, Completer<PlateCheckResult>> _pendingPlateChecks = {};
}
```

### Streams expuestos

```dart
Stream<ChatMessage> get messageStream;
Stream<VehicleRequest> get vehicleRequestStream;
Stream<MeshNode> get nodePositionStream;   // NUEVO — emite cuando un nodo actualiza GPS
```

### Métodos clave

```dart
// Conexión
Future<void> connectToSavedDevice();
Future<void> connectToDevice(ScannedDevice device);
Future<void> disconnect();

// Chat (igual a sirius_porteria)
Future<bool> sendChatMessage(String text, {int? channel, int? destinationId});
List<ChatMessage> getMessagesForDestination(ChatDestination destination);
void clearUnreadChat();
void clearUnreadForDestination(ChatDestination destination);

// Recepción de vehículos — NUEVO FLUJO
Future<PlateCheckResult> checkPlateWithGateway({
  required String cedula,
  required String placa,
  Duration timeout = const Duration(seconds: 30),
});
Future<bool> requestVehicleApproval({
  required String cedula,
  required String placa,
  required int supervisorNodeId,
});
Future<bool> respondToVehicleRequest({
  required VehicleRequest request,
  required String status,
  required String supervisorName,
  String? comment,
});
void addVehicleEntry({
  required String cedula,
  required String placa,
  required String approvedBy,
});
Future<bool> sendVehicleExitToGateway({required String placa});

// Persistencia (igual a sirius_porteria — visit-pattern persistido)
Future<void> _loadPersistedState();
Future<void> _saveVehicleEntries();
Future<void> _saveVehicleRequests();
Future<void> _saveMessageHistory();
Future<void> clearAllData();      // botón "borrar datos" en Settings

// GPS / nodos
List<MeshNode> get nodesWithPosition;
List<NodePositionPoint> getTrackFor(int nodeId);
```

---

## 6. Protocolo de mensajes mesh

Todos los mensajes son texto plano, formato pipe-delimited, sobre `TEXT_MESSAGE_APP`
(salvo posiciones GPS, que usan el `Position` packet nativo de Meshtastic).

### App → Gateway

| Mensaje | Propósito |
|---|---|
| `CONSULTA\|<requestId>\|<cedula>\|<placa>` | Pregunta si la placa está autorizada |
| `ENTRADA_V\|<cedula>\|<placa>\|<aprobadoPor>` | Registrar entrada del vehículo |
| `SALIDA_V\|<placa>` | Registrar salida del vehículo |
| `REGISTRO_MANUAL\|<status>\|<cedula>\|<placa>\|<supervisor>\|<comment>` | Cuando la aprobación fue manual (supervisor), registrar en Airtable |

### Gateway → App

| Mensaje | Propósito |
|---|---|
| `RESPUESTA\|<requestId>\|APROBADO\|<nombreConductor>` | Placa autorizada |
| `RESPUESTA\|<requestId>\|NO_APROBADO` | Placa no autorizada |
| `RESPUESTA\|<requestId>\|ERROR\|<motivo>` | Error de consulta (sin internet en el Pi, etc.) |

> `<requestId>` es generado por la app (`DateTime.now().millisecondsSinceEpoch.toString()`)
> y permite correlacionar la respuesta cuando hay múltiples consultas en vuelo.

### App ↔ App (supervisor)

| Mensaje | Propósito |
|---|---|
| `SOLICITUD_V\|<cedula>\|<placa>` | Solicitud de aprobación manual al supervisor |
| `APROBADO\|<supervisor>\|<comment?>` | Supervisor aprueba |
| `NEGADO\|<supervisor>\|<comment?>` | Supervisor niega |
| `PENDIENTE\|<supervisor>\|<comment?>` | Supervisor pone en espera |

### Posiciones GPS

El SDK `meshtastic_flutter` ya recibe `Position` packets. En `_handlePacket`,
detectar `packet.isPosition == true` y extraer `decoded.position.latitudeI` /
`longitudeI` (formato i32 escalado por 1e7).

```dart
final lat = decoded.position.latitudeI / 1e7;
final lon = decoded.position.longitudeI / 1e7;
_updateNodePosition(fromNodeId, lat, lon);
```

---

## 7. Pantallas

### 7.1 `StartupScreen`

Igual a `sirius_porteria`. Lee `saved_device_address` de SharedPreferences. Si existe
→ `MainScreen`. Si no → `DeviceSelectionScreen`.

### 7.2 `DeviceSelectionScreen`

Igual a `sirius_porteria`:
- Pide permisos BLE (Android: `bluetoothScan`, `bluetoothConnect`, `locationWhenInUse`; iOS: `bluetooth`).
- Escanea dispositivos BLE Meshtastic.
- Al seleccionar uno, guarda dirección+nombre y navega a `MainScreen`.

### 7.3 `MainScreen`

`BottomNavigationBar` con **5 pestañas** (vs 4 en `sirius_porteria`):

| Index | Label | Icono | Pantalla |
|---|---|---|---|
| 0 | Recepción | `Icons.directions_car` | `RecepcionScreen` |
| 1 | Solicitudes | `Icons.list_alt` + badge `pendingRequestsCount` | `RequestsScreen` |
| 2 | Chat | `Icons.chat_bubble` + badge `unreadChatCount` | `ChatScreen` |
| 3 | Mapa | `Icons.map` | `MapScreen` |
| 4 | Settings | `Icons.settings` | `SettingsScreen` |

**Back button (PopScope)** — igual a `sirius_porteria` (sección 10).

### 7.4 `RecepcionScreen`

Flujo de UI:

1. Dos `TextFormField`: **CC** (numérico) y **Placa** (mayúsculas, max 8 chars).
2. Botón "Verificar" → llama `_service.checkPlateWithGateway(cedula, placa)`.
3. Muestra spinner "Consultando gateway…" con timeout de 30s.
4. Según `PlateCheckResult`:
   - **`approved`** → Card verde "✅ AUTORIZADO" + nombre del conductor + botón "Registrar Entrada" (llama `addVehicleEntry` + `sendEntryToGateway`).
   - **`notApproved`** → Card naranja "⚠️ No autorizado" + dropdown de supervisor (nodos online) + botón "Solicitar Aprobación Manual" (envía `SOLICITUD_V`, espera respuesta vía `vehicleRequestStream` / `responseStream`).
   - **`timeout`** o **`error`** → Card roja + botón Reintentar.
5. Al recibir respuesta de supervisor (APROBADO/NEGADO/PENDIENTE), mostrar resultado.
   Si fue APROBADO manualmente, llamar `addVehicleEntry(approvedBy: supervisorName)`
   y `sendRegistroManualToGateway`.
6. Lista de **vehículos activos** abajo (igual a la lista de visitantes de
   `sirius_porteria`) con botón "Salida" por cada uno.

### 7.5 `RequestsScreen`

Idéntica a `sirius_porteria` pero con `VehicleRequest` en lugar de `VisitorRequest`.
Muestra CC + Placa + nodo origen. Botones Aprobar / Negar / Pendiente con campo de
comentario opcional.

### 7.6 `ChatScreen`

**Copia exacta** de `sirius_porteria/lib/screens/chat_screen.dart`:
- Dropdown de destino (canal 0 Primary, canal 1 Supervisores, DMs por nodo online).
- Badges rojos por nodo/canal con no-leídos.
- Burbujas con `DeliveryIndicator` para DMs propios.
- Contador de bytes UTF-8 con límite 237.
- Auto-scroll, fechas separadoras.
- Soporta deep link: cuando se navega con argumento `ChatDestination`, abrir en esa
  conversación (útil para el tap-on-node del mapa).

### 7.7 `MapScreen` — NUEVA

```dart
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_mbtiles/flutter_map_mbtiles.dart';
import 'package:latlong2/latlong.dart';

class MapScreen extends StatefulWidget {
  final MeshtasticService meshtasticService;
  final void Function(ChatDestination) onOpenChat;   // callback para DM al tappear
  // ...
}
```

**Capas (de abajo arriba):**

1. **TileLayer** con `MBTilesTileProvider` cargando `assets/maps/guaicaramo.mbtiles`.
2. **PolylineLayer** con un `Polyline` por cada nodo, dibujando su `_sessionTracks`.
3. **MarkerLayer** con un marker por cada nodo en `nodesWithPosition`:
   - Icono diferenciado: gateway con `Icons.cell_tower`, otros con `Icons.location_pin`.
   - Color por batería (verde >50%, naranja 25-50%, rojo <25%, azul USB).
   - Etiqueta con `node.displayName`.

**Interacciones:**

- Tap en marker → `BottomSheet` con:
  - Nombre del nodo + shortId
  - Última actualización GPS (`positionTime`)
  - Batería / voltaje
  - Botón "Enviar mensaje" → llama `onOpenChat(ChatDestination.directMessage(node))`
    que cambia `_currentIndex = 2` en `MainScreen` y pre-selecciona el DM.

**Control de cámara:**

- Botón flotante "Centrar en mi nodo" → mueve la cámara al `myNodeNum` del cliente.
- Botón "Ver todos" → ajusta zoom para mostrar todos los nodos en bounds.
- Auto-follow opcional: switch que sigue al nodo local cuando se mueve.

**Performance:**

- Solo actualizar markers cuando `nodePositionStream` emita (no en cada
  `notifyListeners`).
- Limitar puntos del track a últimos 500 por nodo (sliding window).

### 7.8 `SettingsScreen`

Igual a `sirius_porteria`:
- Sección "Nodo Conectado" — nombre, MAC/UUID, estado, batería, botón Desconectar.
- Sección "Gateway" — dropdown para elegir cuál nodo es el gateway (auto-detectado de la mesh).
- Sección "Configuración LoRa" — dropdown de región (US 915 / EU 433 / EU 868 / UNSET) + Aplicar.
- Sección "Acciones":
  - Botón "Cambiar Nodo"
  - Botón rojo "**Borrar Datos Almacenados**" con `AlertDialog` de confirmación.

---

## 8. Gateway Python (cambios sobre el del proyecto actual)

Reutilizar `gateway/gateway.py` de `sirius_porteria` y agregar handlers:

### Tabla Airtable nueva: `Placas`

| Campo | Tipo | Notas |
|---|---|---|
| placa | Single line text | PK |
| cedula | Single line text | |
| conductor | Single line text | Nombre del titular |
| autorizado | Checkbox | `true` para acceso aprobado |
| vence | Date | (opcional) fecha de expiración |
| notas | Long text | |

### Handler `CONSULTA`

```python
def handle_consulta(packet, parts):
    request_id, cedula, placa = parts[1], parts[2], parts[3]
    from_node = packet["from"]

    try:
        records = airtable.search('Placas', 'placa', placa.upper())
        if not records:
            send_text(from_node, f"RESPUESTA|{request_id}|NO_APROBADO")
            return

        record = records[0]['fields']
        is_authorized = record.get('autorizado', False)
        vence = record.get('vence')

        # Verificar vencimiento si existe
        if vence and datetime.fromisoformat(vence) < datetime.now():
            send_text(from_node, f"RESPUESTA|{request_id}|NO_APROBADO")
            return

        if is_authorized:
            conductor = record.get('conductor', '')
            send_text(from_node, f"RESPUESTA|{request_id}|APROBADO|{conductor}")
        else:
            send_text(from_node, f"RESPUESTA|{request_id}|NO_APROBADO")
    except Exception as e:
        send_text(from_node, f"RESPUESTA|{request_id}|ERROR|{str(e)[:50]}")
```

### Handlers existentes a portar

- `ENTRADA_V`, `SALIDA_V`, `REGISTRO_MANUAL` → insertan/actualizan en tabla `Registros` de Airtable (similar al `REGISTRO`/`SALIDA` actual de `sirius_porteria`, pero con campos `cedula`/`placa` en vez de `visitor_name`).

---

## 9. Persistencia (igual a `sirius_porteria` mejorado)

**Keys de SharedPreferences:**

```dart
const _savedDeviceAddressKey = 'saved_device_address';
const _savedDeviceNameKey = 'saved_device_name';
const _loraRegionKey = 'lora_region';
const _gatewayNodeIdKey = 'gateway_node_id';
const _vehicleEntriesKey = 'vehicle_entries';
const _vehicleRequestsKey = 'vehicle_requests';
const _messageHistoryKey = 'message_history';
const _lastSessionDateKey = 'last_session_date';
```

**Reglas:**

1. Cargar en el constructor del service (antes del primer `notifyListeners`).
2. Guardar después de **cada mutación** (`add`, `markExited`, `respond`, recepción
   en `_handlePacket`).
3. **Limpieza diaria**: si la última sesión fue otro día, borrar `VehicleEntry` con
   `hasExited == true` y `VehicleRequest` con `isResponded == true`. Mantener los
   activos / pendientes.
4. **NO persistir** `_knownNodes` ni `_sessionTracks` — siempre se reconstruyen desde
   la mesh al conectar (más limpio, evita ghosts de nodos viejos).
5. Cap de mensajes a 100 (sliding window).

---

## 10. Back button (`PopScope`)

`MainScreen` envuelto en `PopScope(canPop: false, ...)`:

- Si `_currentIndex != 0` → volver a la pestaña Recepción (index 0).
- Si ya está en Recepción → `AlertDialog` que muestra cuántos vehículos activos y
  solicitudes pendientes hay, con botones Cancelar / Salir. Si Salir →
  `SystemNavigator.pop()` (Android cierra app; los datos ya están persistidos).

---

## 11. Auto-reconexión BLE

Copiar EXACTO de `sirius_porteria`:

- `_autoReconnectEnabled = true` cuando se conecta.
- `_keepaliveTimer` cada 15s llama `_client!.keepAlive()` (evita drop de iOS por inactividad).
- `_onUnexpectedDisconnect` lanza `_attemptReconnect` con hasta 10 intentos cada 2s.
- En `MainScreen`, escuchar `AppLifecycleState.resumed` y llamar `connectToSavedDevice()`
  si no está conectado.

---

## 12. Bugs conocidos de `sirius_porteria` — NO REPLICAR

Al portar código, evitar estos errores:

1. **`_myNodeId = 0` hardcoded** — usar `_client!.myNodeInfo!.myNodeNum` cuando esté disponible.
2. **Dedupe de paquetes con `Set.first`** — usar `Queue<int>` ordenada para el FIFO.
3. **`respondToRequest` matchea por `fromNodeId`** — debe matchear por `requestId`.
4. **DM delivery tracking asume orden FIFO** — correlacionar por `packetId` del envío
   con el `requestId` del routing packet.
5. **`clearUnreadChat()` no limpia los sets** `_nodesWithUnread` y `_channelsWithUnread`.
6. **`onlineNodes` incluye el nodo local** — filtrar `myNodeNum` del dropdown de DMs.
7. **`_selectedNode = _service.currentGatewayNode` en initState** — async race: usar
   `addListener` o `FutureBuilder`.
8. **Visitantes sin persistencia** — ya resuelto en esta especificación (sección 9).

---

## 13. Permisos

### Android (`android/app/src/main/AndroidManifest.xml`)

```xml
<uses-permission android:name="android.permission.BLUETOOTH" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" />
<uses-permission android:name="android.permission.BLUETOOTH_SCAN"
    android:usesPermissionFlags="neverForLocation" tools:targetApi="31" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" tools:targetApi="31" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
```

### iOS (`ios/Runner/Info.plist`)

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Guaicaramo Control necesita Bluetooth para comunicarse con el nodo Meshtastic</string>
<key>NSBluetoothPeripheralUsageDescription</key>
<string>Guaicaramo Control necesita Bluetooth para comunicarse con el nodo Meshtastic</string>
<key>NSLocationWhenInUseUsageDescription</key>
<string>Guaicaramo Control usa ubicación para mostrar nodos en el mapa</string>
```

---

## 14. Mapa offline — setup detallado

### Generar el `.mbtiles`

1. Instalar [TileMill](https://tilemill-project.github.io/tilemill/) o usar `mb-util` con tiles descargados.
2. Alternativa rápida: usar [Mobile Atlas Creator](https://mobac.sourceforge.io/) (gratis, GUI):
   - Seleccionar área de Guaicaramo (15.000 ha — aprox un bbox de 12×13 km).
   - Source: OpenStreetMap Mapnik o ESRI World Imagery (satélite).
   - Zoom levels: 10–17 (10 ≈ vista regional, 17 ≈ vista de edificios).
   - Output format: **MBTiles SQLite**.
   - Tamaño esperado: 100–250 MB para esa área y rango de zoom.
3. Copiar a `assets/maps/guaicaramo.mbtiles`.
4. Declarar en `pubspec.yaml`:

   ```yaml
   flutter:
     assets:
       - assets/maps/guaicaramo.mbtiles
   ```

### Uso en Flutter

```dart
final mbtiles = await MbTiles(mbtilesPath: pathToCopyFromAsset);

FlutterMap(
  options: MapOptions(
    initialCenter: LatLng(4.36, -72.83),  // Centro aprox de Guaicaramo
    initialZoom: 14,
    minZoom: 10,
    maxZoom: 17,
  ),
  children: [
    TileLayer(
      tileProvider: MbTilesTileProvider(mbtiles: mbtiles),
    ),
    PolylineLayer(polylines: _buildTracks()),
    MarkerLayer(markers: _buildMarkers()),
  ],
);
```

> Los `.mbtiles` no se pueden leer directamente desde `assets/` — hay que copiarlos a
> un path en disco al primer arranque (`getApplicationDocumentsDirectory()`). Hacer
> esto una sola vez y guardar un flag en SharedPreferences.

---

## 15. Plan de implementación por fases

### Fase 1 — Cimientos (1–2 días)

1. `flutter create guaicaramo_control` + copiar `packages/meshtastic_flutter` del proyecto actual.
2. Portar `MeshtasticService` con BLE, conexión, keepalive, auto-reconnect, persistencia.
3. Portar `StartupScreen`, `DeviceSelectionScreen`, `MainScreen` con 5 tabs (todas placeholder excepto Settings).
4. Portar `SettingsScreen` completa.
5. **Verificación**: conectar a un nodo, ver batería, cambiar región LoRa, desconectar.

### Fase 2 — Chat (1 día)

1. Portar `ChatScreen` y modelos relacionados (`ChatMessage`, `ChatDestination`, `DeliveryStatus`).
2. Portar `_handlePacket` con manejo de texto + routing/ACK.
3. Persistencia de mensajes con cap de 100.
4. **Verificación**: enviar/recibir DMs y broadcasts; badges rojos correctos; indicadores de entrega.

### Fase 3 — Recepción de vehículos (2 días)

1. Modelos `VehicleEntry`, `VehicleRequest`, `PlateCheckResult`.
2. Protocolo `CONSULTA` / `RESPUESTA` con `requestId` y `Completer` para correlación.
3. `RecepcionScreen` con flujo: verificar → autorizado-pasa | no-autorizado-pide-supervisor.
4. `RequestsScreen` con aprobar/negar/pendiente.
5. **Verificación end-to-end con un Pi de prueba**: una placa en Airtable, consultar
   desde el portero, recibir APROBADO, registrar entrada, ver en Airtable.

### Fase 4 — Mapa (2 días)

1. Generar `.mbtiles` de Guaicaramo con Mobile Atlas Creator.
2. Integrar `flutter_map` + `flutter_map_mbtiles`.
3. Handler de `Position` packets en `_handlePacket`.
4. `MapScreen` con TileLayer + PolylineLayer (tracks) + MarkerLayer.
5. Tap-on-marker → BottomSheet con info + botón "Enviar mensaje" que navega al chat
   pre-seleccionando el DM.
6. **Verificación**: dos celulares con nodos GPS encendidos en sitios distintos —
   ver los dos pins en el mapa y el track de uno moviéndose.

### Fase 5 — Gateway Python (1 día)

1. Agregar tabla `Placas` en Airtable y poblar con datos de prueba.
2. Implementar handler `CONSULTA` que busque en `Placas`.
3. Portar handlers `ENTRADA_V` / `SALIDA_V` / `REGISTRO_MANUAL` con la nueva tabla `Registros`.
4. **Verificación**: estrés-test con 5 consultas seguidas (no debe haber cross-talk
   por `requestId`).

### Fase 6 — Pulido (1 día)

1. Back button con `PopScope` y conteos en el diálogo.
2. Botón "Borrar Datos" en Settings.
3. Limpieza diaria automática.
4. Iconos de app + splash + nombre comercial.
5. Build APK release + IPA TestFlight.

---

## 16. Checklist final

- [ ] App conecta a nodo BLE y mantiene conexión (keepalive + auto-reconnect).
- [ ] Chat envía y recibe DMs y broadcasts; badges no-leídos por nodo y canal.
- [ ] Indicador de entrega para DMs (sending → delivered/failed).
- [ ] Recepción consulta gateway por placa; flujo APROBADO/NO_APROBADO funciona.
- [ ] No autorizado → solicitud manual al supervisor; supervisor aprueba/niega; portero recibe respuesta.
- [ ] Vehículos activos persisten entre cierres de app y reinicios.
- [ ] Mapa muestra nodos GPS con tracks de sesión sin internet.
- [ ] Tap en nodo del mapa abre DM con ese nodo.
- [ ] Back button no cierra la app sin confirmación.
- [ ] Botón "Borrar Datos" funciona con confirmación.
- [ ] Limpieza diaria automática al cambiar de día.
- [ ] Gateway Python: handler `CONSULTA` responde rápido; handlers de entrada/salida persisten en Airtable.
- [ ] Build Android y iOS funcionan.

---

## 17. Notas de implementación

- **Tono del código**: español para strings de UI, inglés para nombres de variables/clases.
- **No mockear datos** en código de producción. Para pruebas locales sin gateway,
  usar un toggle en Settings que active un "gateway simulado" en proceso.
- **Reusar widgets** `BatteryIndicator` y `DeliveryIndicator` de `sirius_porteria` sin cambios.
- **Logs**: usar prefijos consistentes (`📦 [PACKET]`, `📤 [SEND]`, `🗺️ [MAP]`, `🚗 [VEHICLE]`)
  para facilitar el debug.
- **Versión inicial**: `pubspec.yaml` → `version: 0.1.0+1`.

---

## 18. Referencias

- App existente: `sirius_porteria` — usar como referencia de patrones, especialmente
  `lib/services/meshtastic_service.dart`, `lib/screens/chat_screen.dart` y
  `lib/main.dart`.
- SDK Meshtastic Flutter: en `packages/meshtastic_flutter` del proyecto actual.
- Protocolo Meshtastic: <https://meshtastic.org/docs/development/device/protobufs/>
- `flutter_map`: <https://docs.fleaflet.dev/>
- `flutter_map_mbtiles`: <https://pub.dev/packages/flutter_map_mbtiles>
