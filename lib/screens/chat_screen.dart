import 'dart:async';
import 'package:flutter/material.dart';
import '../models/chat_message.dart';
import '../services/meshtastic_service.dart';
import '../widgets/battery_indicator.dart';
import '../widgets/delivery_indicator.dart';

class ChatScreen extends StatefulWidget {
  final MeshtasticService meshtasticService;

  const ChatScreen({
    super.key,
    required this.meshtasticService,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  StreamSubscription<ChatMessage>? _messageSubscription;

  ChatDestination _selectedDestination = ChatDestination.primaryChannel;
  List<ChatMessage> _filteredMessages = [];
  bool _isSending = false;
  int _currentByteCount = 0;

  MeshtasticService get _service => widget.meshtasticService;

  bool get _isMessageTooLong => _currentByteCount > MeshtasticService.maxMessageBytes;

  @override
  void initState() {
    super.initState();
    debugPrint('🖥️ [CHAT_SCREEN] initState - Suscribiendo a messageStream...');
    _service.addListener(_onServiceChange);
    _messageSubscription = _service.messageStream.listen(
      _onNewMessage,
      onError: (e) => debugPrint('❌ [CHAT_SCREEN] Error en messageStream: $e'),
      onDone: () => debugPrint('⚠️ [CHAT_SCREEN] messageStream cerrado'),
    );
    debugPrint('✅ [CHAT_SCREEN] Suscripción a messageStream completada');
    _updateFilteredMessages();
    _messageController.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    setState(() {
      _currentByteCount = MeshtasticService.getUtf8ByteLength(_messageController.text);
    });
  }

  @override
  void dispose() {
    _messageController.removeListener(_onTextChanged);
    _messageController.dispose();
    _scrollController.dispose();
    _service.removeListener(_onServiceChange);
    _messageSubscription?.cancel();
    super.dispose();
  }

  void _onServiceChange() {
    _updateFilteredMessages();
  }

  void _onNewMessage(ChatMessage message) {
    debugPrint('📬 [CHAT_SCREEN] Mensaje recibido en UI: "${message.messageText}"');
    debugPrint('📬 [CHAT_SCREEN] De: ${message.fromNodeName}, Canal: ${message.channel}, isDM: ${message.isDirectMessage}');
    debugPrint('📬 [CHAT_SCREEN] toNodeId: ${message.toNodeId}, fromNodeId: ${message.fromNodeId}');
    debugPrint('📬 [CHAT_SCREEN] Destino actual: ${_selectedDestination.displayName} (isChannel: ${_selectedDestination.isChannel})');
    debugPrint('📬 [CHAT_SCREEN] Actualizando lista de mensajes...');
    _updateFilteredMessages();
    debugPrint('📬 [CHAT_SCREEN] Mensajes filtrados: ${_filteredMessages.length}');
    _scrollToBottom();
    debugPrint('✅ [CHAT_SCREEN] UI actualizada');
  }

  void _updateFilteredMessages() {
    setState(() {
      _filteredMessages = _service.getMessagesForDestination(_selectedDestination);
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || !_service.isConnected) return;

    setState(() => _isSending = true);

    final success = await _service.sendChatMessage(
      text,
      channel: _selectedDestination.isChannel ? _selectedDestination.channel : null,
      destinationId: _selectedDestination.isChannel ? null : _selectedDestination.nodeId,
    );

    setState(() => _isSending = false);

    if (success) {
      _messageController.clear();
      _scrollToBottom();
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Error al enviar mensaje')),
        );
      }
    }
  }

  List<DropdownMenuItem<ChatDestination>> _buildDestinationItems() {
    final items = <DropdownMenuItem<ChatDestination>>[];

    // Canales
    items.add(DropdownMenuItem(
      value: ChatDestination.primaryChannel,
      child: Row(
        children: [
          const Text('📢 '),
          Text(ChatDestination.primaryChannel.displayName),
        ],
      ),
    ));

    items.add(DropdownMenuItem(
      value: ChatDestination.supervisorsChannel,
      child: Row(
        children: [
          const Text('🔒 '),
          Text(ChatDestination.supervisorsChannel.displayName),
        ],
      ),
    ));

    // Nodos online
    final onlineNodes = _service.onlineNodes;
    if (onlineNodes.isNotEmpty) {
      items.add(const DropdownMenuItem(
        enabled: false,
        value: null,
        child: Divider(),
      ));

      for (final node in onlineNodes) {
        final destination = ChatDestination.directMessage(node);
        items.add(DropdownMenuItem(
          value: destination,
          child: Row(
            children: [
              const Text('👤 '),
              Expanded(
                child: Text(
                  'DM: ${node.displayName} (${node.shortId})',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              BatteryIndicator(
                batteryLevel: node.batteryLevel,
                iconSize: 16,
                showPercentage: false,
              ),
            ],
          ),
        ));
      }
    }

    return items;
  }

  Widget _buildMessageBubble(ChatMessage message, bool showDateSeparator) {
    final alignment = message.isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    final bubbleColor = message.isMine ? Colors.blue.shade100 : Colors.grey.shade200;
    final textAlign = message.isMine ? TextAlign.right : TextAlign.left;

    return Column(
      crossAxisAlignment: alignment,
      children: [
        if (showDateSeparator)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16.0),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  message.formattedDate,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade700,
                  ),
                ),
              ),
            ),
          ),
        Container(
          margin: EdgeInsets.only(
            left: message.isMine ? 48 : 8,
            right: message.isMine ? 8 : 48,
            top: 4,
            bottom: 4,
          ),
          child: Column(
            crossAxisAlignment: alignment,
            children: [
              if (!message.isMine)
                Padding(
                  padding: const EdgeInsets.only(left: 12, bottom: 2),
                  child: Text(
                    '${message.fromNodeName} (!${message.fromNodeId.toRadixString(16)})',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey.shade600,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: bubbleColor,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: alignment,
                  children: [
                    Text(
                      message.messageText,
                      textAlign: textAlign,
                      style: const TextStyle(fontSize: 15),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!message.isDirectMessage)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: Text(
                              'CH${message.channel}',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.grey.shade500,
                              ),
                            ),
                          ),
                        Text(
                          message.formattedTime,
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.grey.shade500,
                          ),
                        ),
                        if (message.isMine)
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: DeliveryIndicator(
                              status: message.deliveryStatus,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMessageList() {
    if (_filteredMessages.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.chat_bubble_outline,
              size: 64,
              color: Colors.grey.shade400,
            ),
            const SizedBox(height: 16),
            Text(
              'No hay mensajes',
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Los mensajes de ${_selectedDestination.displayName}\naparecerán aquí',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey.shade500,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _filteredMessages.length,
      itemBuilder: (context, index) {
        final message = _filteredMessages[index];
        final showDateSeparator = index == 0 ||
            !message.isSameDay(_filteredMessages[index - 1]);
        return _buildMessageBubble(message, showDateSeparator);
      },
    );
  }

  Widget _buildInputArea() {
    final destinationName = _selectedDestination.displayName;
    final maxBytes = MeshtasticService.maxMessageBytes;
    final byteCountColor = _isMessageTooLong ? Colors.red : Colors.grey.shade600;
    final canSend = _service.isConnected && !_isSending && !_isMessageTooLong;

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.grey.shade200,
            blurRadius: 4,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    decoration: InputDecoration(
                      hintText: 'Mensaje a $destinationName',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: _isMessageTooLong
                            ? const BorderSide(color: Colors.red, width: 2)
                            : BorderSide.none,
                      ),
                      filled: true,
                      fillColor: _isMessageTooLong
                          ? Colors.red.shade50
                          : Colors.grey.shade100,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                    ),
                    textInputAction: TextInputAction.send,
                    onSubmitted: canSend ? (_) => _sendMessage() : null,
                    enabled: _service.isConnected,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  decoration: BoxDecoration(
                    color: canSend ? Colors.blue : Colors.grey,
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    icon: _isSending
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.send, color: Colors.white),
                    onPressed: canSend ? _sendMessage : null,
                  ),
                ),
              ],
            ),
            if (_currentByteCount > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4, right: 56),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    '$_currentByteCount/$maxBytes bytes',
                    style: TextStyle(
                      fontSize: 11,
                      color: byteCountColor,
                      fontWeight: _isMessageTooLong ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
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
        title: const Text('Chat Mesh'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Column(
        children: [
          // Selector de destino
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border(
                bottom: BorderSide(color: Colors.grey.shade200),
              ),
            ),
            child: DropdownButtonFormField<ChatDestination>(
              initialValue: _selectedDestination,
              decoration: InputDecoration(
                labelText: 'Enviar a',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              items: _buildDestinationItems(),
              onChanged: (value) {
                if (value != null) {
                  setState(() => _selectedDestination = value);
                  _updateFilteredMessages();
                }
              },
            ),
          ),

          // Lista de mensajes
          Expanded(
            child: _buildMessageList(),
          ),

          // Input de mensaje
          _buildInputArea(),
        ],
      ),
    );
  }
}
