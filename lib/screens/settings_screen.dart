import 'package:flutter/material.dart';
import '../services/meshtastic_service.dart';
import '../widgets/battery_indicator.dart';

class SettingsScreen extends StatefulWidget {
  final MeshtasticService meshtasticService;
  final VoidCallback onDeviceChange;
  final VoidCallback onDisconnect;

  const SettingsScreen({
    super.key,
    required this.meshtasticService,
    required this.onDeviceChange,
    required this.onDisconnect,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  LoraRegion _selectedRegion = LoraRegion.unset;
  bool _isApplyingConfig = false;

  MeshtasticService get _service => widget.meshtasticService;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onServiceChange);
    _loadSavedRegion();
  }

  @override
  void dispose() {
    _service.removeListener(_onServiceChange);
    super.dispose();
  }

  void _onServiceChange() {
    setState(() {});
  }

  Future<void> _loadSavedRegion() async {
    final region = await _service.getSavedLoraRegion();
    setState(() => _selectedRegion = region);
  }

  Future<void> _applyConfiguration() async {
    setState(() => _isApplyingConfig = true);

    final success = await _service.setLoraRegion(_selectedRegion);

    setState(() => _isApplyingConfig = false);

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success
              ? 'Configuración aplicada correctamente'
              : 'Error al aplicar configuración',
        ),
        backgroundColor: success ? Colors.green : Colors.red,
      ),
    );
  }

  Future<void> _disconnectDevice() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Desconectar nodo'),
        content: const Text(
          '¿Estás seguro de que deseas desconectar el nodo? '
          'Deberás seleccionar uno nuevo para continuar.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Desconectar'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _service.disconnectAndClear();
      widget.onDisconnect();
    }
  }

  void _changeDevice() {
    widget.onDeviceChange();
  }

  Widget _buildNodeInfoSection() {
    final deviceName = _service.connectedDeviceName ?? 'Desconocido';
    final deviceMac = _service.connectedDeviceMac ?? 'N/A';
    final isConnected = _service.isConnected;

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.bluetooth,
                  color: isConnected ? Colors.blue : Colors.grey,
                ),
                const SizedBox(width: 12),
                const Text(
                  'Nodo Conectado',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const Divider(),
            const SizedBox(height: 8),
            _buildInfoRow('Nombre', deviceName),
            const SizedBox(height: 8),
            _buildInfoRow('MAC Address', deviceMac),
            const SizedBox(height: 8),
            _buildInfoRow(
              'Estado',
              isConnected ? 'Conectado' : 'Desconectado',
              valueColor: isConnected ? Colors.green : Colors.red,
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Bateria',
                  style: TextStyle(
                    color: Colors.grey.shade600,
                    fontSize: 14,
                  ),
                ),
                BatteryIndicator(
                  batteryLevel: _service.connectedNodeBatteryLevel,
                  voltage: _service.connectedNodeVoltage,
                  iconSize: 20,
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _disconnectDevice,
                icon: const Icon(Icons.bluetooth_disabled),
                label: const Text('Desconectar'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.red,
                  side: const BorderSide(color: Colors.red),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, {Color? valueColor}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.grey.shade600,
            fontSize: 14,
          ),
        ),
        Text(
          value,
          style: TextStyle(
            fontWeight: FontWeight.w500,
            fontSize: 14,
            color: valueColor,
          ),
        ),
      ],
    );
  }

  Widget _buildLoraConfigSection() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.settings_input_antenna, color: Colors.orange),
                SizedBox(width: 12),
                Text(
                  'Configuración LoRa',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const Divider(),
            const SizedBox(height: 8),
            DropdownButtonFormField<LoraRegion>(
              initialValue: _selectedRegion,
              decoration: const InputDecoration(
                labelText: 'Región LoRa',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.public),
              ),
              items: LoraRegion.values.map((region) {
                return DropdownMenuItem(
                  value: region,
                  child: Text(region.displayName),
                );
              }).toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() => _selectedRegion = value);
                }
              },
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _service.isConnected && !_isApplyingConfig
                    ? _applyConfiguration
                    : null,
                icon: _isApplyingConfig
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.check),
                label: Text(
                  _isApplyingConfig ? 'Aplicando...' : 'Aplicar Configuración',
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
            if (!_service.isConnected)
              Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Text(
                  'Conecta un dispositivo para aplicar configuración',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade600,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildActionsSection() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.touch_app, color: Colors.purple),
                SizedBox(width: 12),
                Text(
                  'Acciones',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const Divider(),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _changeDevice,
                icon: const Icon(Icons.bluetooth_searching),
                label: const Text('Cambiar Nodo'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
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
        title: const Text('Configuración del Nodo'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            _buildNodeInfoSection(),
            const SizedBox(height: 16),
            _buildLoraConfigSection(),
            const SizedBox(height: 16),
            _buildActionsSection(),
          ],
        ),
      ),
    );
  }
}
