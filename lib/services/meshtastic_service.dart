import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:meshtastic_flutter/meshtastic_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/chat_message.dart';

const int _maxMessageBytes = 237; // Límite de Meshtastic para mensajes de texto

const String _savedDeviceAddressKey = 'saved_device_address';
const String _savedDeviceNameKey = 'saved_device_name';
const String _loraRegionKey = 'lora_region';
const int _maxMessageHistory = 100;

enum ConnectionStatus {
  disconnected,
  scanning,
  connecting,
  connected,
  error,
}

enum LoraRegion {
  unset('UNSET', 'Sin configurar'),
  us('US', '915 MHz'),
  eu433('EU_433', '433 MHz'),
  eu868('EU_868', '868 MHz');

  final String code;
  final String frequency;

  const LoraRegion(this.code, this.frequency);

  String get displayName => '$code ($frequency)';

  static LoraRegion fromCode(String code) {
    return LoraRegion.values.firstWhere(
      (r) => r.code == code,
      orElse: () => LoraRegion.unset,
    );
  }
}

class ScannedDevice {
  final String name;
  final String address;
  final dynamic rawDevice;

  ScannedDevice({
    required this.name,
    required this.address,
    required this.rawDevice,
  });
}

class ApprovalResponse {
  final String supervisorName;
  final String nodeId;

  ApprovalResponse({required this.supervisorName, required this.nodeId});
}

class MeshtasticService extends ChangeNotifier {
  MeshtasticClient? _client;
  ConnectionStatus _status = ConnectionStatus.disconnected;
  String _statusMessage = 'Desconectado';
  StreamSubscription? _connectionSubscription;
  StreamSubscription? _packetSubscription;

  String? _connectedDeviceName;
  String? _connectedDeviceMac;

  // Chat
  final List<ChatMessage> _messageHistory = [];
  final Map<int, MeshNode> _knownNodes = {};
  final Set<int> _processedPacketIds = {}; // Para evitar procesar paquetes duplicados
  final int _myNodeId = 0;

  // Tracking de entrega de DMs: nodeId destino -> lista de mensajes pendientes
  final Map<int, List<ChatMessage>> _pendingDeliveries = {};
  static const int _deliveryTimeoutSeconds = 45;

  // Solicitudes de visitantes
  final List<VisitorRequest> _pendingRequests = [];

  final _approvalController = StreamController<ApprovalResponse>.broadcast();
  final _messageController = StreamController<ChatMessage>.broadcast();
  final _requestController = StreamController<VisitorRequest>.broadcast();
  final _responseController = StreamController<VisitorResponse>.broadcast();

  Stream<ApprovalResponse> get approvalStream => _approvalController.stream;
  Stream<ChatMessage> get messageStream => _messageController.stream;
  Stream<VisitorRequest> get requestStream => _requestController.stream;
  Stream<VisitorResponse> get responseStream => _responseController.stream;

  List<VisitorRequest> get pendingRequests => _pendingRequests.where((r) => !r.isResponded).toList();
  List<VisitorRequest> get allRequests => List.unmodifiable(_pendingRequests);
  int get pendingRequestsCount => pendingRequests.length;

  ConnectionStatus get status => _status;
  String get statusMessage => _statusMessage;
  bool get isConnected => _status == ConnectionStatus.connected;

  String? get connectedDeviceName => _connectedDeviceName;
  String? get connectedDeviceMac => _connectedDeviceMac;

  List<ChatMessage> get messageHistory => List.unmodifiable(_messageHistory);
  List<MeshNode> get onlineNodes => _knownNodes.values.where((n) => n.isOnline).toList();
  int get myNodeId => _myNodeId;

  List<ChatMessage> getMessagesForDestination(ChatDestination destination) {
    if (destination.isChannel) {
      return _messageHistory
          .where((m) => m.channel == destination.channel && !m.isDirectMessage)
          .toList();
    } else {
      return _messageHistory
          .where((m) =>
              m.isDirectMessage &&
              (m.fromNodeId == destination.nodeId || m.toNodeId == destination.nodeId))
          .toList();
    }
  }

  /// Limpia el historial de mensajes (útil para eliminar mensajes basura)
  void clearMessageHistory() {
    _messageHistory.clear();
    notifyListeners();
    debugPrint('🗑️ [SERVICE] Historial de mensajes limpiado');
  }

  /// Obtiene el ID del nodo local conectado
  int? get myNodeNum => _client?.myNodeInfo?.myNodeNum;

  /// Obtiene el nombre de un nodo desde la base de datos del cliente
  String _getNodeName(int nodeId) {
    // Primero buscar en nuestro cache local
    if (_knownNodes.containsKey(nodeId)) {
      final node = _knownNodes[nodeId]!;
      if (node.nodeName.isNotEmpty) {
        return node.nodeName;
      }
    }

    // Intentar obtener desde nodes del cliente
    try {
      final nodes = _client?.nodes;
      if (nodes != null) {
        final nodeInfo = nodes[nodeId];
        if (nodeInfo?.user?.longName != null && nodeInfo!.user!.longName.isNotEmpty) {
          return nodeInfo.user!.longName;
        }
        if (nodeInfo?.user?.shortName != null && nodeInfo!.user!.shortName.isNotEmpty) {
          return nodeInfo.user!.shortName;
        }
      }
    } catch (e) {
      debugPrint('⚠️ Error obteniendo nombre de nodo: $e');
    }

    // Fallback: ID en formato hexadecimal
    return '!${nodeId.toRadixString(16).padLeft(8, '0')}';
  }

  /// Calcula la longitud en bytes UTF-8 de un texto
  static int getUtf8ByteLength(String text) {
    return utf8.encode(text).length;
  }

  /// Verifica si un mensaje excede el límite de bytes
  static bool isMessageTooLong(String text) {
    return getUtf8ByteLength(text) > _maxMessageBytes;
  }

  /// Límite máximo de bytes para mensajes
  static int get maxMessageBytes => _maxMessageBytes;

  Future<void> _ensureClientInitialized() async {
    if (_client == null) {
      _client = MeshtasticClient();
      await _client!.initialize();
    }
  }

  // Device persistence
  Future<String?> getSavedDeviceAddress() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_savedDeviceAddressKey);
  }

  Future<String?> getSavedDeviceName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_savedDeviceNameKey);
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
    _connectedDeviceName = null;
    _connectedDeviceMac = null;
  }

  // LoRa region persistence
  Future<LoraRegion> getSavedLoraRegion() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(_loraRegionKey);
    return code != null ? LoraRegion.fromCode(code) : LoraRegion.unset;
  }

  Future<void> saveLoraRegion(LoraRegion region) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_loraRegionKey, region.code);
  }

  Future<bool> setLoraRegion(LoraRegion region) async {
    if (!isConnected || _client == null) {
      return false;
    }

    try {
      final configMessage = 'CONFIG|LORA_REGION|${region.code}';
      await _client!.sendTextMessage(configMessage, channel: 0);
      await saveLoraRegion(region);
      return true;
    } catch (e) {
      debugPrint('Error configurando región LoRa: $e');
      return false;
    }
  }

  // Device scanning
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

  // Connection methods
  Future<void> connectToSavedDevice() async {
    final savedAddress = await getSavedDeviceAddress();
    final savedName = await getSavedDeviceName();
    if (savedAddress != null) {
      _connectedDeviceName = savedName;
      _connectedDeviceMac = savedAddress;
      await connectToDeviceByAddress(savedAddress);
    }
  }

  Future<void> connectToDeviceByAddress(String address) async {
    try {
      _updateStatus(ConnectionStatus.connecting, 'Conectando...');
      await _ensureClientInitialized();

      _connectionSubscription = _client!.connectionStream.listen((status) {
        final stateStr = status.state.toString().toLowerCase();
        if (stateStr.contains('connected') && !stateStr.contains('dis')) {
          _updateStatus(ConnectionStatus.connected, 'Conectado');
          _applyInitialConfig();
        } else if (stateStr.contains('disconnect')) {
          _updateStatus(ConnectionStatus.disconnected, 'Desconectado');
        }
      });

      debugPrint('🔊 [LISTENER] Registrando listener de packetStream...');
      _packetSubscription = _client!.packetStream.listen(
        _handlePacket,
        onError: (e) => debugPrint('❌ [PACKET_ERROR] Error en packetStream: $e'),
        onDone: () => debugPrint('⚠️ [PACKET_DONE] packetStream cerrado'),
      );
      debugPrint('✅ [LISTENER] Listener de packetStream registrado');

      await for (final device in _client!.scanForDevices()) {
        if (device.remoteId.toString() == address) {
          _connectedDeviceName = device.platformName;
          _connectedDeviceMac = address;
          _updateStatus(ConnectionStatus.connecting, 'Conectando a ${device.platformName}...');
          await _client!.connectToDevice(device);
          break;
        }
      }
    } catch (e) {
      _updateStatus(ConnectionStatus.error, 'Error: ${e.toString()}');
    }
  }

  Future<void> connectToDevice(ScannedDevice device) async {
    try {
      _updateStatus(ConnectionStatus.connecting, 'Conectando a ${device.name}...');
      await _ensureClientInitialized();

      _connectionSubscription = _client!.connectionStream.listen((status) {
        final stateStr = status.state.toString().toLowerCase();
        if (stateStr.contains('connected') && !stateStr.contains('dis')) {
          _updateStatus(ConnectionStatus.connected, 'Conectado');
          _applyInitialConfig();
        } else if (stateStr.contains('disconnect')) {
          _updateStatus(ConnectionStatus.disconnected, 'Desconectado');
        }
      });

      debugPrint('🔊 [LISTENER] Registrando listener de packetStream...');
      _packetSubscription = _client!.packetStream.listen(
        _handlePacket,
        onError: (e) => debugPrint('❌ [PACKET_ERROR] Error en packetStream: $e'),
        onDone: () => debugPrint('⚠️ [PACKET_DONE] packetStream cerrado'),
      );
      debugPrint('✅ [LISTENER] Listener de packetStream registrado');

      await _client!.connectToDevice(device.rawDevice);
      _connectedDeviceName = device.name;
      _connectedDeviceMac = device.address;
      await saveDeviceInfo(device.address, device.name);
    } catch (e) {
      _updateStatus(ConnectionStatus.error, 'Error: ${e.toString()}');
    }
  }

  Future<void> _applyInitialConfig() async {
    final savedRegion = await getSavedLoraRegion();
    if (savedRegion != LoraRegion.unset) {
      await setLoraRegion(savedRegion);
    }
  }

  Future<void> disconnect() async {
    try {
      await _connectionSubscription?.cancel();
      await _packetSubscription?.cancel();
      await _client?.disconnect();
      _client = null;
      _updateStatus(ConnectionStatus.disconnected, 'Desconectado');
    } catch (e) {
      _updateStatus(ConnectionStatus.error, 'Error al desconectar: ${e.toString()}');
    }
  }

  Future<void> disconnectAndClear() async {
    await disconnect();
    await clearSavedDevice();
  }

  // Chat messaging
  Future<bool> sendChatMessage(String text, {int? channel, int? destinationId}) async {
    if (!isConnected || _client == null) {
      return false;
    }

    try {
      if (destinationId != null) {
        // DM - Mensaje directo a un nodo específico
        debugPrint('📤 [SEND] Enviando DM a nodo: $destinationId (0x${destinationId.toRadixString(16)})');
        debugPrint('📤 [SEND] Texto: "$text"');
        await _client!.sendTextMessage(text, destinationId: destinationId);
      } else {
        // Mensaje a canal (broadcast)
        debugPrint('📤 [SEND] Enviando a canal: ${channel ?? 0}');
        debugPrint('📤 [SEND] Texto: "$text"');
        await _client!.sendTextMessage(text, channel: channel ?? 0);
      }

      // Add own message to history
      final isDM = destinationId != null;
      final myMessage = ChatMessage(
        messageText: text,
        fromNodeId: _myNodeId,
        fromNodeName: _connectedDeviceName ?? 'Yo',
        timestamp: DateTime.now(),
        channel: channel ?? 0,
        toNodeId: destinationId,
        isDirectMessage: isDM,
        isMine: true,
        deliveryStatus: isDM ? DeliveryStatus.sending : DeliveryStatus.none,
      );
      _addMessageToHistory(myMessage);
      _messageController.add(myMessage);

      // Para DMs, rastrear entrega pendiente con timeout
      if (destinationId != null) {
        _pendingDeliveries.putIfAbsent(destinationId, () => []);
        _pendingDeliveries[destinationId]!.add(myMessage);
        _scheduleDeliveryTimeout(myMessage, destinationId);
      }

      debugPrint('✅ [SEND] Mensaje enviado correctamente (delivery: ${myMessage.deliveryStatus})');
      return true;
    } catch (e, stackTrace) {
      debugPrint('❌ [SEND] Error enviando mensaje: $e');
      debugPrint('❌ [STACK] $stackTrace');
      return false;
    }
  }

  // Visit request - puede enviar a un nodo específico o broadcast
  Future<bool> sendVisitRequest({
    required String visitorName,
    required String reason,
    required String area,
    int? destinationNodeId,
  }) async {
    if (!isConnected || _client == null) {
      return false;
    }

    try {
      final message = 'VISITA|$visitorName|$reason|$area';
      if (destinationNodeId != null) {
        // Enviar como DM a un nodo específico
        debugPrint('📤 [VISIT] Enviando solicitud a nodo: $destinationNodeId');
        await _client!.sendTextMessage(message, destinationId: destinationNodeId);
      } else {
        // Broadcast al canal 0
        debugPrint('📤 [VISIT] Enviando solicitud broadcast al canal 0');
        await _client!.sendTextMessage(message, channel: 0);
      }
      return true;
    } catch (e) {
      debugPrint('Error enviando solicitud: $e');
      return false;
    }
  }

  /// Responder a una solicitud de visitante
  Future<bool> respondToRequest({
    required int destinationNodeId,
    required String status, // 'APROBADO', 'NEGADO', 'PENDIENTE'
    required String supervisorName,
    String? comment,
  }) async {
    if (!isConnected || _client == null) {
      return false;
    }

    try {
      final message = comment != null && comment.isNotEmpty
          ? '$status|$supervisorName|$comment'
          : '$status|$supervisorName';

      debugPrint('📤 [RESPONSE] Enviando respuesta "$status" a nodo: $destinationNodeId');
      await _client!.sendTextMessage(message, destinationId: destinationNodeId);

      // Marcar solicitud como respondida localmente
      for (final request in _pendingRequests) {
        if (request.fromNodeId == destinationNodeId && !request.isResponded) {
          request.isResponded = true;
          request.responseStatus = status;
          break;
        }
      }
      notifyListeners();

      return true;
    } catch (e) {
      debugPrint('Error enviando respuesta: $e');
      return false;
    }
  }

  /// Marcar solicitud como respondida
  void markRequestResponded(int requestId, String status) {
    for (final request in _pendingRequests) {
      if (request.requestId == requestId) {
        request.isResponded = true;
        request.responseStatus = status;
        break;
      }
    }
    notifyListeners();
  }

  void _handlePacket(dynamic packet) {
    debugPrint('📦 [PACKET] Recibido paquete: ${packet.runtimeType}');

    try {
      // Obtener ID del paquete para deduplicación
      final int packetId = packet.id as int? ?? 0;
      if (packetId != 0 && _processedPacketIds.contains(packetId)) {
        debugPrint('⚠️ [PACKET] Paquete duplicado ignorado: $packetId');
        return;
      }

      // Extraer info básica del paquete
      final int fromNodeId = packet.from as int? ?? 0;
      final int? toNodeId = packet.to as int?;
      final int channel = packet.channel as int? ?? 0;

      // Verificar si es DM (to != broadcast)
      final bool isDM = toNodeId != null && toNodeId != 0xFFFFFFFF && toNodeId != 0;

      // Obtener tipo de paquete para logging
      String packetType = 'Desconocido';
      bool isEncrypted = false;
      bool hasDecoded = false;
      try {
        packetType = packet.packetTypeDescription as String? ?? 'Desconocido';
        isEncrypted = packet.isEncrypted as bool? ?? false;
        hasDecoded = packet.isDecoded as bool? ?? false;
      } catch (_) {}

      debugPrint('📦 [PACKET] Tipo: $packetType, De: $fromNodeId, Para: $toNodeId, Canal: $channel');
      debugPrint('📦 [PACKET] isDM: $isDM, encrypted: $isEncrypted, decoded: $hasDecoded');

      // Handle node info packets - actualizar cache de nodos
      try {
        if (packet.isNodeInfo == true) {
          final nodes = _client?.nodes;
          if (nodes != null && nodes.containsKey(fromNodeId)) {
            final nodeInfo = nodes[fromNodeId];
            final nodeName = nodeInfo?.user?.longName ?? nodeInfo?.user?.shortName ?? '';
            if (nodeName.isNotEmpty) {
              debugPrint('👤 [NODE] Info de nodo actualizada: $nodeName (ID: $fromNodeId)');
              _updateKnownNode(fromNodeId, nodeName);
            }
          }
        }
      } catch (_) {}

      // ========== DETECTAR PAQUETES DE ROUTING (ACK/NACK) ==========
      try {
        final bool isRouting = packet.isRouting as bool? ?? false;
        if (isRouting) {
          debugPrint('📨 [ROUTING] Paquete de routing recibido de nodo $fromNodeId');
          _handleRoutingPacket(packet);
          if (packetId != 0) _processedPacketIds.add(packetId);
          return;
        }
      } catch (_) {}

      // Verificar si es mensaje de texto
      bool isTextMessage = false;
      try {
        isTextMessage = packet.isTextMessage as bool? ?? false;
      } catch (_) {}

      // Ignorar paquetes que NO son texto (telemetría, posición, etc.)
      // pero permitir paquetes con payload decodificado que podrían ser texto
      if (!isTextMessage) {
        // Si tiene payload decodificado, intentar procesarlo de todos modos
        bool hasPayload = false;
        try {
          final decoded = packet.decoded;
          hasPayload = decoded != null && decoded.payload != null;
        } catch (_) {}

        if (!hasPayload) {
          debugPrint('⏭️ [PACKET] Ignorando paquete no-texto: $packetType');
          return;
        }
        debugPrint('🔍 [PACKET] Paquete no marcado como texto pero tiene payload, intentando procesar...');
      }

      // Extraer texto del mensaje - SIEMPRE usar utf8.decode para soportar emojis
      String? text;

      try {
        final decoded = packet.decoded;
        if (decoded != null) {
          final payload = decoded.payload;
          if (payload is List<int> && payload.isNotEmpty) {
            // UTF-8 decode es necesario para emojis (4 bytes) y caracteres especiales
            text = utf8.decode(payload, allowMalformed: true);
            debugPrint('🔤 [DECODE] Payload decodificado con UTF-8: "$text"');
          }
        }
      } catch (e) {
        debugPrint('⚠️ [DECODE] Error decodificando payload: $e');
        // Fallback: intentar con textMessage del wrapper (no soporta emojis bien)
        try {
          text = packet.textMessage as String?;
        } catch (_) {}
      }

      // Si no hay texto, ignorar
      if (text == null || text.isEmpty) {
        debugPrint('⚠️ [PACKET] Mensaje de texto vacío');
        return;
      }

      // Obtener nombre del remitente
      final String fromName = _getNodeName(fromNodeId);

      debugPrint('📩 [MSG] Mensaje recibido: "$text"');
      debugPrint('📩 [MSG] De: $fromName (ID: $fromNodeId)');
      debugPrint('📩 [MSG] Canal: $channel');

      // Actualizar cache de nodos con el remitente
      if (fromNodeId != 0) {
        _updateKnownNode(fromNodeId, fromName);
        debugPrint('👤 [NODE] Nodo agregado/actualizado: $fromName (ID: $fromNodeId)');
      }

      // ========== DETECTAR SOLICITUDES DE VISITANTES ==========
      if (text.startsWith('VISITA|')) {
        final parts = text.split('|');
        if (parts.length >= 4) {
          final request = VisitorRequest(
            requestId: DateTime.now().millisecondsSinceEpoch,
            visitorName: parts[1],
            reason: parts[2],
            area: parts[3],
            fromNodeId: fromNodeId,
            fromNodeName: fromName,
            timestamp: DateTime.now(),
          );
          debugPrint('📋 [REQUEST] Solicitud de visitante recibida: ${parts[1]}');
          _pendingRequests.add(request);
          _requestController.add(request);
          notifyListeners(); // Para actualizar badge
        }
        // NO agregar al chat normal - terminar aquí
        if (packetId != 0) _processedPacketIds.add(packetId);
        return;
      }

      // ========== DETECTAR RESPUESTAS A SOLICITUDES ==========
      if (text.startsWith('APROBADO|') ||
          text.startsWith('NEGADO|') ||
          text.startsWith('PENDIENTE|')) {
        final parts = text.split('|');
        if (parts.length >= 2) {
          final response = VisitorResponse(
            status: parts[0],
            supervisorName: parts[1],
            comment: parts.length > 2 ? parts[2] : null,
            fromNodeId: fromNodeId,
            timestamp: DateTime.now(),
          );
          debugPrint('📬 [RESPONSE] Respuesta recibida: ${parts[0]} de ${parts[1]}');
          _responseController.add(response);

          // También emitir al viejo approvalStream para compatibilidad
          if (parts[0] == 'APROBADO') {
            _approvalController.add(ApprovalResponse(
              supervisorName: parts[1],
              nodeId: fromNodeId.toString(),
            ));
          }
        }
        // NO agregar al chat normal - terminar aquí
        if (packetId != 0) _processedPacketIds.add(packetId);
        return;
      }

      // ========== MENSAJE NORMAL DE CHAT ==========
      final bool isDirectMessage = isDM;
      debugPrint('📝 [MSG] isDirectMessage: $isDirectMessage, toNodeId: $toNodeId');

      final chatMessage = ChatMessage(
        messageText: text,
        fromNodeId: fromNodeId,
        fromNodeName: fromName,
        timestamp: DateTime.now(),
        channel: channel,
        toNodeId: toNodeId,
        isDirectMessage: isDirectMessage,
        isMine: false,
      );

      debugPrint('💬 [CHAT] Agregando mensaje al historial (isDM: $isDirectMessage)...');
      _addMessageToHistory(chatMessage);

      debugPrint('📤 [STREAM] Emitiendo al messageStream...');
      _messageController.add(chatMessage);

      // Marcar paquete como procesado para evitar duplicados
      if (packetId != 0) {
        _processedPacketIds.add(packetId);
        // Limpiar IDs antiguos para no acumular memoria (mantener últimos 100)
        if (_processedPacketIds.length > 100) {
          _processedPacketIds.remove(_processedPacketIds.first);
        }
      }

      debugPrint('✅ [DONE] Mensaje procesado correctamente (packetId: $packetId)');

    } catch (e, stackTrace) {
      debugPrint('❌ [ERROR] Error procesando paquete: $e');
      debugPrint('❌ [STACK] $stackTrace');
    }
  }

  /// Programa timeout para un mensaje DM pendiente
  void _scheduleDeliveryTimeout(ChatMessage message, int destinationId) {
    Future.delayed(const Duration(seconds: _deliveryTimeoutSeconds), () {
      if (message.deliveryStatus == DeliveryStatus.sending) {
        message.deliveryStatus = DeliveryStatus.failed;
        _pendingDeliveries[destinationId]?.remove(message);
        debugPrint('⏰ [DELIVERY] Timeout para mensaje a nodo $destinationId');
        notifyListeners();
      }
    });
  }

  /// Procesa paquetes de routing (ACK/NACK) para actualizar estado de entrega
  void _handleRoutingPacket(dynamic packet) {
    try {
      final int fromNodeId = packet.from as int? ?? 0;
      final decoded = packet.decoded;
      if (decoded == null) return;

      // Parsear el payload de routing
      final payload = decoded.payload;
      if (payload == null || payload is! List<int> || payload.isEmpty) return;

      final routing = Routing.fromBuffer(payload);

      if (routing.hasErrorReason()) {
        final error = routing.errorReason;
        debugPrint('📨 [ROUTING] Routing de nodo $fromNodeId, error: $error');

        if (error == Routing_Error.NONE) {
          // ACK exitoso - marcar como entregado
          _updateDeliveryStatus(fromNodeId, DeliveryStatus.delivered);
        } else {
          // Error de routing - marcar como fallido
          debugPrint('❌ [ROUTING] Error de entrega: $error');
          _updateDeliveryStatus(fromNodeId, DeliveryStatus.failed);
        }
      }
    } catch (e) {
      debugPrint('⚠️ [ROUTING] Error procesando paquete routing: $e');
    }
  }

  /// Actualiza el estado de entrega del mensaje pendiente mas antiguo hacia un nodo
  void _updateDeliveryStatus(int nodeId, DeliveryStatus status) {
    final pending = _pendingDeliveries[nodeId];
    if (pending != null && pending.isNotEmpty) {
      final message = pending.removeAt(0);
      message.deliveryStatus = status;
      debugPrint('📨 [DELIVERY] Mensaje a nodo $nodeId -> $status');
      notifyListeners();
    }
  }

  void _addMessageToHistory(ChatMessage message) {
    // Verificar si el mensaje ya existe (evitar duplicados)
    if (_messageHistory.any((m) => m.id == message.id)) {
      debugPrint('⚠️ [HISTORY] Mensaje duplicado ignorado: ${message.id}');
      return;
    }

    _messageHistory.add(message);
    // FIFO limit
    while (_messageHistory.length > _maxMessageHistory) {
      _messageHistory.removeAt(0);
    }
    notifyListeners();
  }

  /// Obtiene el nivel de batería de un nodo desde el SDK
  int? _getNodeBatteryLevel(int nodeId) {
    try {
      final nodeInfo = _client?.nodes[nodeId];
      return nodeInfo?.batteryLevel;
    } catch (_) {
      return null;
    }
  }

  /// Obtiene el voltaje de un nodo desde el SDK
  double? _getNodeVoltage(int nodeId) {
    try {
      final nodeInfo = _client?.nodes[nodeId];
      return nodeInfo?.voltage;
    } catch (_) {
      return null;
    }
  }

  /// Obtiene batería del nodo local conectado
  int? get connectedNodeBatteryLevel {
    final myNum = myNodeNum;
    if (myNum == null) return null;
    return _getNodeBatteryLevel(myNum);
  }

  /// Obtiene voltaje del nodo local conectado
  double? get connectedNodeVoltage {
    final myNum = myNodeNum;
    if (myNum == null) return null;
    return _getNodeVoltage(myNum);
  }

  void _updateKnownNode(int nodeId, String nodeName) {
    if (nodeId == 0) return;
    _knownNodes[nodeId] = MeshNode(
      nodeId: nodeId,
      nodeName: nodeName,
      isOnline: true,
      lastSeen: DateTime.now(),
      batteryLevel: _getNodeBatteryLevel(nodeId),
      voltage: _getNodeVoltage(nodeId),
    );
    notifyListeners();
  }

  void _updateStatus(ConnectionStatus status, String message) {
    _status = status;
    _statusMessage = message;
    notifyListeners();
  }

  @override
  void dispose() {
    _connectionSubscription?.cancel();
    _packetSubscription?.cancel();
    _approvalController.close();
    _messageController.close();
    _requestController.close();
    _responseController.close();
    _client?.disconnect();
    super.dispose();
  }
}
