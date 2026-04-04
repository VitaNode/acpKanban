import 'package:flutter/material.dart';
import '../models/connection_config.dart';
import '../services/connection_config_manager.dart';
import '../services/smart_connect.dart';
import '../services/acp_client.dart';

class ConnectionSettingsScreen extends StatefulWidget {
  final ACPClient acpClient;
  final ConnectionMode currentMode;
  final String userId;
  final Function(ConnectionPath newMode, String? url)? onConnectionChanged;

  const ConnectionSettingsScreen({
    super.key,
    required this.acpClient,
    required this.currentMode,
    required this.userId,
    this.onConnectionChanged,
  });

  @override
  State<ConnectionSettingsScreen> createState() =>
      _ConnectionSettingsScreenState();
}

class _ConnectionSettingsScreenState extends State<ConnectionSettingsScreen> {
  late ConnectionMode _selectedMode;
  late TextEditingController _localIpController;
  late TextEditingController _relayHostController;
  late TextEditingController _relayTokenController;
  late TextEditingController _cloudUrlController;
  late TextEditingController _localPortController;
  late TextEditingController _relayPortController;
  late TextEditingController _apiPortController;
  late TextEditingController _systemBaseUrlController;
  late TextEditingController _systemApiKeyController;
  late TextEditingController _summaryModelController;
  late TextEditingController _embeddingModelController;

  late int _relayPort;
  late int _localPort;
  late int _apiPort;

  bool _isConnecting = false;
  String _connectionStatus = 'Disconnected';
  bool _isScanning = false;
  String? _scannedIp;

  @override
  void initState() {
    super.initState();
    _selectedMode = widget.currentMode;
    _localIpController = TextEditingController();
    _relayHostController = TextEditingController(text: '35.211.219.123');
    _relayTokenController = TextEditingController();
    _cloudUrlController =
        TextEditingController(text: 'ws://35.211.219.123:8766/direct');
    _localPortController = TextEditingController(text: '8766');
    _relayPortController = TextEditingController(text: '8766');
    _apiPortController = TextEditingController(text: '8000');
    _systemBaseUrlController = TextEditingController();
    _systemApiKeyController = TextEditingController();
    _summaryModelController = TextEditingController(text: 'gpt-4o-mini');
    _embeddingModelController =
        TextEditingController(text: 'text-embedding-3-small');
    _relayPort = 8766;
    _localPort = 8766;
    _apiPort = 8000;
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final configManager = await ConnectionConfigManager.getInstance();
    final config = await configManager.loadConfig();
    setState(() {
      _selectedMode = config.preferredMode;
      _localIpController.text = config.localIp ?? '';
      _relayHostController.text = config.relayHost ?? '35.211.219.123';
      _relayTokenController.text = config.relayToken ?? '';
      _cloudUrlController.text =
          config.cloudUrl ?? 'ws://35.211.219.123:8766/direct';
      _localPortController.text = (config.localPort ?? 8766).toString();
      _relayPortController.text = (config.relayPort ?? 8766).toString();
      _apiPortController.text = (config.apiPort ?? 8000).toString();
      
      _systemBaseUrlController.text = config.systemConfig.baseUrl ?? '';
      _systemApiKeyController.text = config.systemConfig.apiKey ?? '';
      _summaryModelController.text = config.systemConfig.summaryModel;
      _embeddingModelController.text = config.systemConfig.embeddingModel;

      _relayPort = config.relayPort ?? 8766;
      _localPort = config.localPort ?? 8766;
      _apiPort = config.apiPort ?? 8000;
    });
  }

  @override
  void dispose() {
    _localIpController.dispose();
    _relayHostController.dispose();
    _relayTokenController.dispose();
    _cloudUrlController.dispose();
    _localPortController.dispose();
    _relayPortController.dispose();
    _apiPortController.dispose();
    _systemBaseUrlController.dispose();
    _systemApiKeyController.dispose();
    _summaryModelController.dispose();
    _embeddingModelController.dispose();
    super.dispose();
  }

  Future<void> _scanMdns() async {
    setState(() {
      _isScanning = true;
      _scannedIp = null;
    });

    try {
      final ip = await SmartConnect.discoverLocalMac();
      setState(() {
        _scannedIp = ip;
        if (ip != null) {
          _localIpController.text = ip;
        }
      });
    } catch (e) {
      setState(() {
        _scannedIp = 'Scan failed';
      });
    } finally {
      setState(() {
        _isScanning = false;
      });
    }
  }

  Future<void> _saveAndConnect() async {
    final configManager = await ConnectionConfigManager.getInstance();

    final config = ConnectionConfig(
      preferredMode: _selectedMode,
      localIp: _localIpController.text.isEmpty ? null : _localIpController.text,
      localPort: _localPort,
      apiPort: _apiPort,
      relayHost:
          _relayHostController.text.isEmpty ? null : _relayHostController.text,
      relayPort: _relayPort,
      relayToken: _relayTokenController.text.isEmpty
          ? null
          : _relayTokenController.text,
      cloudUrl:
          _cloudUrlController.text.isEmpty ? null : _cloudUrlController.text,
      autoFallback: false,
      systemConfig: SystemAgentConfig(
        baseUrl: _systemBaseUrlController.text.isEmpty ? null : _systemBaseUrlController.text,
        apiKey: _systemApiKeyController.text.isEmpty ? null : _systemApiKeyController.text,
        summaryModel: _summaryModelController.text,
        embeddingModel: _embeddingModelController.text,
      ),
    );

    await configManager.saveConfig(config);

    setState(() {
      _isConnecting = true;
      _connectionStatus = 'Connecting...';
    });

    try {
      widget.acpClient.disconnect();

      final acpConfig = ACPConfig.fromConnectionConfig(config, widget.userId);
      await widget.acpClient.smartConnect(acpConfig);
      await widget.acpClient.initialize(acpConfig.systemConfig);

      setState(() {
        _connectionStatus = 'Connected';
      });
      widget.onConnectionChanged?.call(
        widget.acpClient.activeMode,
        widget.acpClient.activeUrl,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Connected successfully!')),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      setState(() {
        _connectionStatus = 'Failed: ${e.toString()}';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Connection failed: $e')),
        );
      }
    } finally {
      setState(() {
        _isConnecting = false;
      });
    }
  }

  Color _getStatusColor() {
    if (_connectionStatus.startsWith('Connected')) return Colors.green;
    if (_connectionStatus.startsWith('Failed')) return Colors.red;
    return Colors.orange;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Connection Settings'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Connection Mode',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            _buildModeSelector(),
            const SizedBox(height: 24),
            _buildModeSpecificFields(),
            const SizedBox(height: 24),
            _buildSystemAgentFields(),
            const SizedBox(height: 24),
            _buildConnectionStatus(),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isConnecting ? null : _saveAndConnect,
                icon: _isConnecting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.power),
                label: Text(_isConnecting ? 'Connecting...' : 'Connect'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModeSelector() {
    return Row(
      children: [
        _buildModeButton(
          mode: ConnectionMode.local,
          icon: Icons.home,
          label: 'Local',
        ),
        const SizedBox(width: 8),
        _buildModeButton(
          mode: ConnectionMode.relay,
          icon: Icons.cloud,
          label: 'Relay',
        ),
        const SizedBox(width: 8),
        _buildModeButton(
          mode: ConnectionMode.cloud,
          icon: Icons.public,
          label: 'Cloud',
        ),
      ],
    );
  }

  Widget _buildModeButton({
    required ConnectionMode mode,
    required IconData icon,
    required String label,
  }) {
    final isSelected = _selectedMode == mode;
    return Expanded(
      child: OutlinedButton.icon(
        onPressed: () => setState(() => _selectedMode = mode),
        icon: Icon(icon),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          backgroundColor: isSelected
              ? Theme.of(context).primaryColor.withOpacity(0.1)
              : null,
          side: BorderSide(
            color: isSelected ? Theme.of(context).primaryColor : Colors.grey,
            width: isSelected ? 2 : 1,
          ),
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
      ),
    );
  }

  Widget _buildModeSpecificFields() {
    switch (_selectedMode) {
      case ConnectionMode.local:
        return _buildLocalFields();
      case ConnectionMode.relay:
        return _buildRelayFields();
      case ConnectionMode.cloud:
        return _buildCloudFields();
    }
  }

  Widget _buildLocalFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Local Connection',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _isScanning ? null : _scanMdns,
                icon: _isScanning
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.search),
                label: Text(_isScanning ? 'Scanning...' : 'Scan mDNS'),
              ),
            ),
          ],
        ),
        if (_scannedIp != null) ...[
          const SizedBox(height: 8),
          Text(
            _scannedIp!.startsWith('Scan') ? _scannedIp! : 'Found: $_scannedIp',
            style: TextStyle(
              color: _scannedIp!.startsWith('Scan') ? Colors.red : Colors.green,
              fontSize: 12,
            ),
          ),
        ],
        const SizedBox(height: 12),
        TextField(
          controller: _localIpController,
          decoration: const InputDecoration(
            labelText: 'Manual IP Address',
            hintText: '192.168.1.100',
            border: OutlineInputBorder(),
          ),
          keyboardType: TextInputType.text,
          autocorrect: false,
          enableSuggestions: false,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _localPortController,
          decoration: const InputDecoration(
            labelText: 'WebSocket Port',
            border: OutlineInputBorder(),
          ),
          keyboardType: TextInputType.number,
          onChanged: (v) =>
              setState(() => _localPort = int.tryParse(v) ?? 8766),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _apiPortController,
          decoration: const InputDecoration(
            labelText: 'API Port',
            hintText: '8000',
            border: OutlineInputBorder(),
          ),
          keyboardType: TextInputType.number,
          onChanged: (v) => setState(() => _apiPort = int.tryParse(v) ?? 8000),
        ),
      ],
    );
  }

  Widget _buildRelayFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Relay Connection',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _relayHostController,
          decoration: const InputDecoration(
            labelText: 'Relay Host',
            hintText: '35.211.219.123 or mybot.siliconpulse.cc',
            border: OutlineInputBorder(),
          ),
          keyboardType: TextInputType.text,
          autocorrect: false,
          enableSuggestions: false,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _relayPortController,
          decoration: const InputDecoration(
            labelText: 'Port',
            border: OutlineInputBorder(),
          ),
          keyboardType: TextInputType.number,
          onChanged: (v) =>
              setState(() => _relayPort = int.tryParse(v) ?? 8766),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _relayTokenController,
          decoration: const InputDecoration(
            labelText: 'Token (optional)',
            hintText: 'Your relay token',
            border: OutlineInputBorder(),
          ),
          obscureText: true,
        ),
      ],
    );
  }

  Widget _buildCloudFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Cloud Direct Connection',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _cloudUrlController,
          decoration: const InputDecoration(
            labelText: 'Cloud URL',
            hintText: 'ws://host:port/direct',
            border: OutlineInputBorder(),
          ),
        ),
      ],
    );
  }

  Widget _buildSystemAgentFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'System Agent (Summary & Embedding)',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _systemBaseUrlController,
          decoration: const InputDecoration(
            labelText: 'Base URL',
            hintText: 'https://api.openai.com/v1',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _systemApiKeyController,
          decoration: const InputDecoration(
            labelText: 'API Key',
            hintText: 'sk-...',
            border: OutlineInputBorder(),
          ),
          obscureText: true,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _summaryModelController,
          decoration: const InputDecoration(
            labelText: 'Summary Model',
            hintText: 'gpt-4o-mini',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _embeddingModelController,
          decoration: const InputDecoration(
            labelText: 'Embedding Model',
            hintText: 'text-embedding-3-small',
            border: OutlineInputBorder(),
          ),
        ),
      ],
    );
  }

  Widget _buildConnectionStatus() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: _getStatusColor(),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _connectionStatus,
              style: const TextStyle(fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}
