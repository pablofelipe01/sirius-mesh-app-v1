# Blueprint: App de Comunicación Mesh con Flutter + Meshtastic BLE

> Este documento describe la arquitectura y patrones de una app Flutter que se comunica
> vía Meshtastic (LoRa + BLE) con una red mesh de nodos. Fue construida iterativamente
> con Claude Code. Úsalo como contexto para que otro Claude Code construya una app similar
> con las características que necesites.

---

## 1. Qué Hace Esta App

Una app de portería/seguridad donde:

- **Portero** (en la entrada) registra visitantes y envía solicitudes de aprobación
- **Supervisor** (remoto) recibe las solicitudes y aprueba/niega desde su celular
- **Gateway** (Raspberry Pi) registra todo en Airtable automáticamente
- **Chat** permite comunicación libre entre todos los nodos de la red mesh

Todo funciona **sin internet ni WiFi** — usa radios LoRa (Meshtastic) conectados por Bluetooth (BLE) al celular.

---

## 2. Stack Tecnológico

| Componente | Tecnología |
|---|---|
| App móvil | Flutter (Dart) |
| Comunicación BLE | SDK local fork de `meshtastic_flutter` |
| Protocolo mesh | Meshtastic (LoRa) |
| State management | `ChangeNotifier` + `Stream`s |
| Persistencia local | `shared_preferences` |
| Permisos BLE | `permission_handler` |
| Gateway | Python en Raspberry Pi |
| Base de datos | Airtable (vía API REST desde el Pi) |

### pubspec.yaml (dependencias clave)

```yaml
dependencies:
  flutter:
    sdk: flutter
  meshtastic_flutter:
    path: packages/meshtastic_flutter  # Fork local del SDK
  shared_preferences: ^2.2.2
  permission_handler: ^12.0.1
  cupertino_icons: ^1.0.8
```

---

## 3. Estructura del Proyecto

```
lib/
├── main.dart                          # Entry point + FormScreen + MainScreen + DeviceSelection
├── models/
│   └── chat_message.dart              # Todos los modelos de datos
├── services/
│   └── meshtastic_service.dart        # Toda la lógica BLE + mesh + estado
├── screens/
│   ├── chat_screen.dart               # Chat (canales broadcast + DMs)
│   ├── requests_screen.dart           # Vista de supervisor (aprobar/negar)
│   └── settings_screen.dart           # Config de dispositivo, gateway, LoRa
└── widgets/
    ├── delivery_indicator.dart        # Iconos de estado de entrega
    └── battery_indicator.dart         # Indicador de batería de nodos

packages/
└── meshtastic_flutter/                # Fork local del SDK Meshtastic BLE
    └── lib/src/
        ├── meshtastic_client.dart     # Cliente BLE wrapper
        └── models/                    # Packet, connection state, etc.

gateway/
└── airtable_patch.py                  # Script Python para el Pi gateway
```

---

## 4. Arquitectura Central: El Servicio

El corazón de la app es **un solo servicio** (`MeshtasticService`) que:

1. Maneja la conexión BLE al dispositivo Meshtastic
2. Envía y recibe mensajes por la red mesh
3. Mantiene el estado de nodos, mensajes, visitantes
4. Notifica a la UI via `ChangeNotifier` + `Stream`s

### Patrón: ChangeNotifier + Streams

```dart
class MeshtasticService extends ChangeNotifier with WidgetsBindingObserver {
  // === Estado reactivo (UI se reconstruye con notifyListeners()) ===
  ConnectionStatus _status = ConnectionStatus.disconnected;
  List<MeshNode> _knownNodes = [];
  List<ChatMessage> _messageHistory = [];
  List<VisitorRequest> _pendingRequests = [];
  List<ActiveVisitor> _activeVisitors = [];
  int _unreadChatCount = 0;

  // === Streams (para eventos en tiempo real) ===
  final _messageController = StreamController<ChatMessage>.broadcast();
  final _requestController = StreamController<VisitorRequest>.broadcast();
  final _responseController = StreamController<VisitorResponse>.broadcast();

  Stream<ChatMessage> get messageStream => _messageController.stream;
  Stream<VisitorRequest> get requestStream => _requestController.stream;
  Stream<VisitorResponse> get responseStream => _responseController.stream;
}
```

**Por qué este patrón:**
- `notifyListeners()` es para estado general (conexión, listas de nodos, contadores)
- `Stream`s son para eventos puntuales que las pantallas necesitan capturar (nueva solicitud, respuesta recibida)
- Las pantallas hacen `addListener()` Y `stream.listen()` según necesiten

### Cómo lo consume la UI

```dart
class _FormScreenState extends State<FormScreen> {
  late MeshtasticService _service;
  StreamSubscription? _responseSubscription;

  @override
  void initState() {
    super.initState();
    _service = widget.service;
    _service.addListener(_onServiceChange);  // Rebuild on any state change
    _responseSubscription = _service.responseStream.listen(_onResponse);  // Specific event
  }

  void _onServiceChange() => setState(() {});  // Rebuild widget

  void _onResponse(VisitorResponse response) {
    // Handle specific approval/denial
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChange);
    _responseSubscription?.cancel();
    super.dispose();
  }
}
```

---

## 5. Modelos de Datos

### ChatMessage

```dart
class ChatMessage {
  final String id;              // UUID único
  final String messageText;
  final int fromNodeId;
  final String fromNodeName;
  final DateTime timestamp;
  final int channel;            // 0 = principal, 1 = supervisores
  final int? toNodeId;          // null = broadcast, valor = DM
  final bool isDirectMessage;
  final bool isMine;            // true si lo envié yo
  DeliveryStatus deliveryStatus; // sending, delivered, failed, none
}
```

### DeliveryStatus (tracking de entrega para DMs)

```dart
enum DeliveryStatus {
  sending,    // Reloj gris — esperando ACK
  delivered,  // Doble check verde — ACK recibido
  failed,     // X roja — routing error
  none,       // Check simple gris — broadcast o recibido
}
```

### MeshNode

```dart
class MeshNode {
  final int nodeId;
  final String nodeName;
  final bool isOnline;
  final DateTime? lastSeen;
  final int? batteryLevel;     // 0-100, >100 = USB
  final double? voltage;

  String get displayName => nodeName.isNotEmpty ? nodeName : shortId;
  String get shortId => '!0x${nodeId.toRadixString(16)}';
  bool get isUsbPowered => (batteryLevel ?? 0) > 100;
}
```

### VisitorRequest / VisitorResponse / ActiveVisitor

```dart
class VisitorRequest {
  final String requestId;
  final String visitorName, reason, area;
  final int fromNodeId;
  final String fromNodeName;
  final DateTime timestamp;
  bool isResponded;
  String responseStatus;  // APROBADO, NEGADO, PENDIENTE
}

class VisitorResponse {
  final String status;          // APROBADO, NEGADO, PENDIENTE
  final String supervisorName;
  final String? comment;
  bool get isApproved => status == 'APROBADO';
}

class ActiveVisitor {
  final String visitorName, reason, area;
  final DateTime entryTime;
  DateTime? exitTime;
  bool get hasExited => exitTime != null;
}
```

### ChatDestination (a dónde enviar mensajes)

```dart
class ChatDestination {
  final String label;
  final int? channel;         // Para broadcast (0 o 1)
  final MeshNode? node;       // Para DM

  static ChatDestination primaryChannel = ChatDestination(label: 'Canal 0', channel: 0);
  static ChatDestination supervisorsChannel = ChatDestination(label: 'Canal 1', channel: 1);
  static ChatDestination directMessage(MeshNode node) => ChatDestination(label: node.displayName, node: node);
}
```

---

## 6. Sistema de Mensajes con Prefijos

Los mensajes en la red mesh son texto plano. Usamos **prefijos separados por pipe** (`|`) para diferenciar tipos:

| Prefijo | Quién lo envía | Propósito | Formato |
|---|---|---|---|
| `VISITA\|` | Portero → Supervisor | Solicitud de visita | `VISITA\|nombre\|motivo\|área` |
| `APROBADO\|` | Supervisor → Portero | Aprobar visita | `APROBADO\|supervisor\|comentario` |
| `NEGADO\|` | Supervisor → Portero | Negar visita | `NEGADO\|supervisor\|comentario` |
| `PENDIENTE\|` | Supervisor → Portero | Marcar pendiente | `PENDIENTE\|supervisor` |
| `REGISTRO\|` | Supervisor → Gateway | Log en Airtable | `REGISTRO\|status\|nombre\|motivo\|área\|supervisor\|comentario` |
| `SALIDA\|` | Portero → Gateway | Registrar salida | `SALIDA\|nombre` |
| *(sin prefijo)* | Cualquiera | Chat normal | texto libre |

### Cómo se parsean (en el servicio)

```dart
void _handlePacket(MeshPacket packet) {
  // 1. Deduplicar por packet ID
  if (_processedPacketIds.contains(packet.id)) return;
  _processedPacketIds.add(packet.id);

  // 2. Extraer texto del payload
  String text = utf8.decode(packet.payload, allowMalformed: true);

  // 3. Rutear por prefijo
  if (text.startsWith('VISITA|')) {
    final parts = text.split('|');
    final request = VisitorRequest(
      visitorName: parts[1],
      reason: parts[2],
      area: parts[3],
      // ...
    );
    _pendingRequests.add(request);
    _requestController.add(request);
    notifyListeners();
  }
  else if (text.startsWith('APROBADO|') || text.startsWith('NEGADO|') || text.startsWith('PENDIENTE|')) {
    final parts = text.split('|');
    final response = VisitorResponse(
      status: parts[0],
      supervisorName: parts[1],
      comment: parts.length > 2 ? parts[2] : null,
    );
    _responseController.add(response);
  }
  else {
    // Chat normal
    final message = ChatMessage(
      messageText: text,
      fromNodeId: packet.fromNodeId,
      // ...
    );
    _messageHistory.add(message);
    _messageController.add(message);
    _unreadChatCount++;
    notifyListeners();
  }
}
```

---

## 7. Conexión BLE — Flujo Completo

### Flujo de conexión inicial

```
App abre
  → StartupScreen verifica SharedPreferences
  → ¿Hay dispositivo guardado?
    SÍ → connectToSavedDevice() → MainScreen
    NO → DeviceSelectionScreen → scanDevices() → seleccionar → connectToDevice() → MainScreen
```

### Auto-reconexión

```dart
// Se activa automáticamente después de la primera conexión exitosa
bool _autoReconnectEnabled = false;

// En connectToDevice():
_autoReconnectEnabled = true;

// Cuando se desconecta inesperadamente:
void _onDisconnect() {
  if (_autoReconnectEnabled) {
    _attemptReconnect();  // Hasta 10 intentos, 2s entre cada uno
  }
}

// Lifecycle del app (iOS mata BLE en background):
void didChangeAppLifecycleState(AppLifecycleState state) {
  if (state == AppLifecycleState.resumed && _autoReconnectEnabled) {
    connectToSavedDevice();
  }
}
```

### Keepalive (fix para iOS)

```dart
// iOS desconecta BLE si no hay actividad
Timer? _keepaliveTimer;

void _startKeepalive() {
  _keepaliveTimer = Timer.periodic(Duration(seconds: 15), (_) {
    _client.keepAlive();  // Ping silencioso al dispositivo BLE
  });
}
```

### Persistencia del dispositivo

```dart
// Guardar dispositivo seleccionado
Future<void> saveDeviceInfo(String address, String name) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('device_address', address);
  await prefs.setString('device_name', name);
}

// Recuperar al abrir la app
Future<String?> getSavedDeviceAddress() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString('device_address');
}
```

---

## 8. El Chat — Implementación Detallada

### Destinos del chat

El chat soporta tres tipos de destino:

1. **Canal broadcast** — Todos los nodos en la red lo reciben
2. **Canal supervisores** — Solo nodos en canal 1
3. **DM (mensaje directo)** — Solo un nodo específico lo recibe

```dart
// Construir lista de destinos
List<ChatDestination> _buildDestinations() {
  return [
    ChatDestination.primaryChannel,       // Canal 0
    ChatDestination.supervisorsChannel,   // Canal 1
    // DMs a cada nodo conocido:
    ...service.onlineNodes.map((node) => ChatDestination.directMessage(node)),
    ...service.preloadedNodes.map((node) => ChatDestination.directMessage(node)),
  ];
}
```

### Envío de mensajes

```dart
Future<void> sendChatMessage(String text, {int? channel, int? destinationId}) async {
  // Crear mensaje local inmediatamente
  final message = ChatMessage(
    id: DateTime.now().millisecondsSinceEpoch.toString(),
    messageText: text,
    fromNodeId: myNodeNum,
    fromNodeName: 'Yo',
    isMine: true,
    deliveryStatus: destinationId != null ? DeliveryStatus.sending : DeliveryStatus.none,
    isDirectMessage: destinationId != null,
    toNodeId: destinationId,
    channel: channel ?? 0,
  );

  _messageHistory.add(message);
  _messageController.add(message);
  notifyListeners();

  // Enviar por BLE
  if (destinationId != null) {
    // DM — enviar a nodo específico
    await _client.sendDirectMessage(text, destinationId);
    _trackPendingDelivery(message);  // Esperar ACK
  } else {
    // Broadcast — enviar a canal
    await _client.sendTextMessage(text, channel: channel ?? 0);
  }
}
```

### Tracking de entrega (para DMs)

```dart
Map<int, List<ChatMessage>> _pendingDeliveries = {};

void _trackPendingDelivery(ChatMessage message) {
  final nodeId = message.toNodeId!;
  _pendingDeliveries.putIfAbsent(nodeId, () => []);
  _pendingDeliveries[nodeId]!.add(message);

  // Timeout: si no hay ACK en 45s, marcar como failed
  Future.delayed(Duration(seconds: 45), () {
    if (message.deliveryStatus == DeliveryStatus.sending) {
      message.deliveryStatus = DeliveryStatus.failed;
      notifyListeners();
    }
  });
}

// Cuando llega un routing packet (ACK/NACK):
void _handleRoutingPacket(MeshPacket packet) {
  final routingError = packet.routingError;  // 0 = success, otro = error
  final requestId = packet.requestId;

  // Buscar mensaje pendiente que matchee
  for (var entry in _pendingDeliveries.entries) {
    for (var msg in entry.value) {
      if (msg.id == requestId.toString()) {
        msg.deliveryStatus = routingError == 0
          ? DeliveryStatus.delivered
          : DeliveryStatus.failed;
        notifyListeners();
        break;
      }
    }
  }
}
```

### Filtrado de mensajes por destino

```dart
List<ChatMessage> _getFilteredMessages() {
  if (_selectedDestination == null) return [];

  return _service.messageHistory.where((msg) {
    if (_selectedDestination!.node != null) {
      // DM: mostrar mensajes entre yo y este nodo
      final nodeId = _selectedDestination!.node!.nodeId;
      return msg.isDirectMessage && (msg.fromNodeId == nodeId || msg.toNodeId == nodeId);
    } else {
      // Canal: mostrar mensajes de este canal que NO sean DM
      return !msg.isDirectMessage && msg.channel == _selectedDestination!.channel;
    }
  }).toList();
}
```

### Indicadores de no leídos

```dart
// En el servicio:
Set<int> _nodesWithUnread = {};      // Nodos con DMs sin leer
Set<int> _channelsWithUnread = {};   // Canales con mensajes sin leer

// Al recibir un mensaje:
void _onMessageReceived(ChatMessage msg) {
  if (msg.isDirectMessage) {
    _nodesWithUnread.add(msg.fromNodeId);
  } else {
    _channelsWithUnread.add(msg.channel);
  }
  _unreadChatCount++;
  notifyListeners();
}

// Al abrir un chat específico:
void clearUnreadForDestination(ChatDestination dest) {
  if (dest.node != null) {
    _nodesWithUnread.remove(dest.node!.nodeId);
  } else if (dest.channel != null) {
    _channelsWithUnread.remove(dest.channel);
  }
  _recalculateUnreadCount();
  notifyListeners();
}
```

### UI del Chat

```dart
// Selector de destino con badges de no leídos
DropdownButton<ChatDestination>(
  value: _selectedDestination,
  items: destinations.map((dest) {
    final hasUnread = dest.node != null
      ? _service.hasUnreadFromNode(dest.node!.nodeId)
      : _service.hasUnreadOnChannel(dest.channel!);

    return DropdownMenuItem(
      value: dest,
      child: Row(children: [
        Text(dest.label),
        if (hasUnread) ...[
          SizedBox(width: 8),
          Container(  // Punto rojo
            width: 8, height: 8,
            decoration: BoxDecoration(color: Colors.red, shape: BoxShape.circle),
          ),
        ],
      ]),
    );
  }).toList(),
);

// Lista de mensajes con separadores de fecha
ListView.builder(
  reverse: true,  // Nuevos abajo
  itemCount: messages.length,
  itemBuilder: (context, index) {
    final msg = messages[messages.length - 1 - index];
    final showDate = _shouldShowDateSeparator(index);

    return Column(children: [
      if (showDate) _DateSeparator(date: msg.formattedDate),
      _MessageBubble(
        message: msg,
        showDelivery: msg.isMine && msg.isDirectMessage,
      ),
    ]);
  },
);

// Contador de bytes UTF-8 en input (máx 237 bytes Meshtastic)
TextField(
  onChanged: (text) {
    setState(() {
      _currentByteCount = _service.getUtf8ByteLength(text);
    });
  },
  decoration: InputDecoration(
    suffixText: '$_currentByteCount/237',
    suffixStyle: TextStyle(
      color: _currentByteCount > 237 ? Colors.red : Colors.grey,
    ),
  ),
);
```

---

## 9. Nodos Preloaded (Hardcoded)

Para que la app siempre tenga nodos disponibles como destino (incluso antes de descubrirlos por mesh), se precargan nodos conocidos:

```dart
final List<MeshNode> _preloadedNodes = [
  MeshNode(nodeId: 0x9ea29bc4, nodeName: 'Mission Pack'),
  MeshNode(nodeId: 0x7c1a5974, nodeName: 'Pablo A'),
  MeshNode(nodeId: 0xf515b946, nodeName: 'Pablo Long'),
  MeshNode(nodeId: 0x455250c3, nodeName: 'David_Inge'),
  // etc.
];
```

El **gateway** es uno de estos nodos (configurable desde Settings). Por defecto es el Mission Pack. Se persiste en SharedPreferences:

```dart
int _currentGatewayNodeId = 0x9ea29bc4;  // Default

Future<void> setGatewayNode(int nodeId) async {
  _currentGatewayNodeId = nodeId;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt('gateway_node_id', nodeId);
  notifyListeners();
}
```

---

## 10. Flujo de Solicitudes de Visita (End-to-End)

```
PORTERO                          SUPERVISOR                       GATEWAY (Pi)
   │                                │                                │
   │  VISITA|Juan|Reunión|Área1     │                                │
   │ ──────────────────────────────>│                                │
   │           (DM vía mesh)        │                                │
   │                                │                                │
   │                                │ Ve solicitud en RequestsScreen │
   │                                │ Escribe comentario             │
   │                                │ Click "Aprobar"                │
   │                                │                                │
   │  APROBADO|Supervisor1|Bienvenido                                │
   │ <──────────────────────────────│                                │
   │           (DM vía mesh)        │                                │
   │                                │                                │
   │ Muestra tarjeta verde          │   [espera 3 segundos]          │
   │ Agrega a visitantes activos    │                                │
   │ Reset form después de 3s       │ REGISTRO|APROBADO|Juan|Reunión|Área1|Supervisor1|Bienvenido
   │                                │ ──────────────────────────────>│
   │                                │          (DM vía mesh)         │
   │                                │                                │ POST Airtable
   │                                │                                │ Guarda record_id
   │                                │                                │
   │ [Visitante se va]              │                                │
   │ Click "Registrar Salida"       │                                │
   │                                │                                │
   │  SALIDA|Juan                   │                                │
   │ ─────────────────────────────────────────────────────────────-->│
   │           (DM vía mesh)                                         │ PATCH Airtable
   │                                                                 │ Hora Salida = now
```

### La pausa de 3 segundos es CRÍTICA

```dart
Future<void> respondToRequest(int destinationNodeId, String status, ...) async {
  // 1. Enviar respuesta al portero
  await _client.sendDirectMessage(responseText, destinationNodeId);

  // 2. ESPERAR — BLE no puede manejar dos DMs rápidos a nodos diferentes
  await Future.delayed(Duration(seconds: 3));

  // 3. Ahora sí enviar el registro al gateway
  await sendRegistroToGateway(status, visitorName, reason, area, supervisor, comment);
}
```

---

## 11. Gotchas de BLE/Meshtastic

Estas son las lecciones aprendidas que **DEBES** implementar:

### 1. No enviar DMs rápidos consecutivos
BLE no puede manejar dos mensajes directos a nodos diferentes sin pausa.
**Solución:** `await Future.delayed(Duration(seconds: 2-3))` entre envíos.

### 2. Siempre await los envíos
Nunca hacer fire-and-forget con mensajes mesh.
```dart
// MAL:
_client.sendDirectMessage(text, nodeId);  // No await!

// BIEN:
await _client.sendDirectMessage(text, nodeId);
```

### 3. iOS mata conexiones BLE inactivas
**Solución:** Keepalive timer cada 15 segundos.

### 4. iOS mata BLE al ir a background
**Solución:** `WidgetsBindingObserver` + reconectar en `resumed`.

### 5. Auto-reconexión con límite
Reconectar automáticamente pero con máximo de intentos para no quemar batería.
```dart
// 10 intentos, 2 segundos entre cada uno
// Desactivar si el usuario desconecta manualmente
```

### 6. Emojis requieren UTF-8 decode explícito
El SDK base no decodifica bien caracteres multibyte.
```dart
String text = utf8.decode(packet.payload, allowMalformed: true);
```

### 7. Deduplicación de paquetes
El mismo paquete puede llegar múltiples veces en una red mesh.
```dart
Set<int> _processedPacketIds = {};
// Limitar a 100 para no crecer indefinidamente
if (_processedPacketIds.length > 100) {
  _processedPacketIds = _processedPacketIds.skip(50).toSet();
}
```

### 8. Límite de 237 bytes por mensaje
Meshtastic tiene un límite de payload. Emojis = 4 bytes. Siempre validar.
```dart
int getUtf8ByteLength(String text) => utf8.encode(text).length;
bool isMessageTooLong(String text) => getUtf8ByteLength(text) > 237;
```

---

## 12. Gateway (Raspberry Pi)

El gateway es un nodo Meshtastic conectado a una Raspberry Pi que corre un script Python.

### Qué hace

1. Escucha mensajes `REGISTRO|...` → POST a Airtable (nueva visita)
2. Escucha mensajes `SALIDA|...` → PATCH a Airtable (hora de salida)
3. Confirma con `REGISTRO_OK|nombre` y `SALIDA_OK|nombre`
4. Opcionalmente publica en MQTT

### Estructura Airtable

| Campo | Tipo | Ejemplo |
|---|---|---|
| Nombre Visitante | Text | Juan Pérez |
| Motivo | Text | Reunión |
| Area | Text | Área 1 |
| Estado | Select | APROBADO / NEGADO / PENDIENTE |
| Supervisor | Text | Pablo |
| Comentario | Text | Bienvenido |
| Fecha Solicitud | DateTime | 2024-01-15 10:30 |
| Hora Entrada | DateTime | 2024-01-15 10:31 |
| Hora Salida | DateTime | 2024-01-15 11:45 |
| Nodo Origen | Text | !0x7c1a5974 |

### Script Python (simplificado)

```python
import requests

AIRTABLE_TOKEN = os.environ['AIRTABLE_API_TOKEN']
BASE_ID = 'appXXXXX'
TABLE_NAME = 'Visitantes'
pending_visits = {}  # nombre -> record_id

def handle_registro(message_text):
    parts = message_text.split('|')
    # REGISTRO|status|nombre|motivo|area|supervisor|comentario
    status, nombre, motivo, area, supervisor = parts[1], parts[2], parts[3], parts[4], parts[5]
    comentario = parts[6] if len(parts) > 6 else ''

    record = airtable_create_record({
        'Nombre Visitante': nombre,
        'Motivo': motivo,
        'Area': area,
        'Estado': status,
        'Supervisor': supervisor,
        'Comentario': comentario,
        'Hora Entrada': datetime.now().isoformat(),
    })

    if status == 'APROBADO':
        pending_visits[nombre.lower()] = record['id']

    send_mesh_message(f'REGISTRO_OK|{nombre}')

def handle_salida(message_text):
    parts = message_text.split('|')
    nombre = parts[1]
    record_id = pending_visits.get(nombre.lower())

    if record_id:
        airtable_update_record(record_id, {
            'Hora Salida': datetime.now().isoformat()
        })
        del pending_visits[nombre.lower()]

    send_mesh_message(f'SALIDA_OK|{nombre}')
```

---

## 13. Navegación de la App

```
StartupScreen
  ├── DeviceSelectionScreen (si no hay dispositivo guardado)
  │     └── Scan BLE → seleccionar → connectToDevice()
  │
  └── MainScreen (NavigationBar con 4 tabs)
        ├── Tab 0: FormScreen        — Portero (registro de visitantes)
        ├── Tab 1: RequestsScreen    — Supervisor (aprobar/negar)
        ├── Tab 2: ChatScreen        — Chat mesh (canales + DMs)
        └── Tab 3: SettingsScreen    — Configuración
```

Badges en la barra de navegación:
- **Requests:** Muestra contador de solicitudes pendientes
- **Chat:** Muestra contador de mensajes no leídos

---

## 14. Permisos (Android/iOS)

```dart
Future<bool> _requestPermissions() async {
  final statuses = await [
    Permission.bluetooth,
    Permission.bluetoothScan,
    Permission.bluetoothConnect,
    Permission.location,
  ].request();

  return statuses.values.every((s) => s.isGranted);
}
```

---

## 15. Cómo Adaptar Este Blueprint

Para crear una app nueva basada en este patrón:

### Mantener (funciona bien)
- La arquitectura de un solo servicio con ChangeNotifier + Streams
- El sistema de prefijos por pipe para diferenciar tipos de mensaje
- El manejo de BLE (auto-reconnect, keepalive, lifecycle)
- El tracking de delivery status para DMs
- La deduplicación de paquetes
- Los nodos preloaded

### Personalizar
- **Prefijos de mensajes:** Cambiar `VISITA|`, `REGISTRO|`, etc. por los que necesites
- **Modelos de datos:** Adaptar VisitorRequest/Response a tu dominio
- **Pantallas:** Las que necesites según tu caso de uso
- **Gateway:** Cambiar Airtable por otra base de datos o API
- **Nodos preloaded:** Poner los IDs de tus dispositivos

### Ejemplo: App de Riego Agrícola

```
Prefijos:
  RIEGO|zona|minutos          → Solicitar riego
  RIEGO_OK|zona               → Confirmación
  SENSOR|zona|humedad|temp    → Lectura de sensor
  ALERTA|zona|tipo|valor      → Alerta automática

Pantallas:
  - Dashboard (estado de zonas)
  - Control (activar/desactivar riego)
  - Sensores (lecturas en tiempo real)
  - Chat (comunicación entre operadores)
  - Settings (gateway, dispositivos)
```

---

## 16. Debug Logging

Usamos emojis como prefijos en debugPrint para filtrar fácilmente:

```dart
debugPrint('📦 [PACKET] Received from ${packet.fromNodeId}');
debugPrint('📩 [MSG] New message: $text');
debugPrint('🔤 [DECODE] UTF-8 decode: ${text.length} chars');
debugPrint('🔄 [RECONNECT] Attempt $attempt of 10');
debugPrint('💓 [KEEPALIVE] Ping sent');
debugPrint('✅ [ACK] Delivery confirmed for $messageId');
debugPrint('❌ [NACK] Delivery failed for $messageId');
debugPrint('👥 [NODE] Updated: ${node.displayName} battery=${node.batteryLevel}%');
```

---

## 17. Resumen Rápido para Claude Code

> **Eres un asistente construyendo una app Flutter que se comunica por Meshtastic (BLE + LoRa mesh).
> La app usa un solo servicio central (`MeshtasticService`) que extiende `ChangeNotifier` y expone `Stream`s.
> Los mensajes mesh son texto plano con prefijos separados por pipe (`|`).
> El SDK de Meshtastic es un fork local en `packages/meshtastic_flutter/`.
> BLE tiene gotchas importantes: no enviar DMs rápidos consecutivos (2-3s delay),
> usar keepalive cada 15s para iOS, auto-reconectar al volver del background,
> deduplicar paquetes, y siempre decodificar UTF-8 explícitamente.
> El gateway es un Raspberry Pi con Python que registra en Airtable.**
