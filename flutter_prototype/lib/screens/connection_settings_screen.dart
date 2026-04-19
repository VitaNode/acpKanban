import 'package:flutter/material.dart';
import '../models/connection_config.dart';
import '../services/connection_config_manager.dart';
import '../services/smart_connect.dart';
import '../services/acp_client.dart';
import '../constants/app_constants.dart';

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
  late TextEditingController _userIdController;
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
    _userIdController = TextEditingController(text: widget.userId);
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
      _userIdController.text = config.userId ?? widget.userId;
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
    _userIdController.dispose();
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
      userId: _userIdController.text.isEmpty ? null : _userIdController.text,
      autoFallback: false,
      systemConfig: SystemAgentConfig(
        baseUrl: _systemBaseUrlController.text.isEmpty ? null : _systemBaseUrlController.text,
        apiKey: _systemApiKeyController.text.isEmpty ? null : _systemApiKeyController.text,
        summaryModel: _summaryModelController.text,
        embeddingModel: _embeddingModelController.text,
      ),
    );

    await configManager.saveConfig(config);

    if (mounted) {
      setState(() {
        _isConnecting = true;
        _connectionStatus = 'Connecting...';
      });
    }

    try {
      widget.acpClient.disconnect();

      final acpConfig = ACPConfig.fromConnectionConfig(config, widget.userId);
      await widget.acpClient.smartConnect(acpConfig);
      await widget.acpClient.initialize(acpConfig.systemConfig);

      if (mounted) {
        setState(() {
          _connectionStatus = 'Connected';
        });
      }
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
      if (mounted) {
        setState(() {
          _connectionStatus = 'Failed: ${e.toString()}';
        });
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Connection failed: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isConnecting = false;
        });
      }
    }
  }

  Color _getStatusColor() {
    if (_connectionStatus.startsWith('Connected')) return AppConstants.successColor;
    if (_connectionStatus.startsWith('Failed')) return AppConstants.errorColor;
    return Colors.orange;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppConstants.backgroundColor,
      appBar: AppBar(
        title: const Text('Connection Settings'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppConstants.space16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'CONNECTION MODE',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: AppConstants.space12),
            _buildModeSelector(),
            const SizedBox(height: AppConstants.space24),
            _buildModeSpecificFields(),
            const SizedBox(height: AppConstants.space32),
            Text(
              'SYSTEM AGENT (LLM)',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: AppConstants.space12),
            _buildSystemAgentFields(),
            const SizedBox(height: AppConstants.space32),
            _buildConnectionStatus(),
            const SizedBox(height: AppConstants.space24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isConnecting ? null : _saveAndConnect,
                icon: _isConnecting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.power_settings_new_rounded),
                label: Text(_isConnecting ? 'CONNECTING...' : 'SAVE & CONNECT'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: AppConstants.space16),
                ),
              ),
            ),
            const SizedBox(height: AppConstants.space32),
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
          icon: Icons.home_rounded,
          label: 'Local',
        ),
        const SizedBox(width: AppConstants.space8),
        _buildModeButton(
          mode: ConnectionMode.relay,
          icon: Icons.cloud_sync_rounded,
          label: 'Relay',
        ),
        const SizedBox(width: AppConstants.space8),
        _buildModeButton(
          mode: ConnectionMode.cloud,
          icon: Icons.public_rounded,
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
      child: Material(
        color: isSelected ? AppConstants.primaryColor.withOpacity(0.1) : AppConstants.surfaceColor,
        borderRadius: BorderRadius.circular(AppConstants.space8),
        child: InkWell(
          onTap: () => setState(() => _selectedMode = mode),
          borderRadius: BorderRadius.circular(AppConstants.space8),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: AppConstants.space12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppConstants.space8),
              border: Border.all(
                color: isSelected ? AppConstants.primaryColor : Colors.grey.shade200,
                width: isSelected ? 2 : 1,
              ),
            ),
            child: Column(
              children: [
                Icon(icon, color: isSelected ? AppConstants.primaryColor : AppConstants.textHint, size: 20),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    color: isSelected ? AppConstants.primaryColor : AppConstants.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModeSpecificFields() {
    return Container(
      padding: const EdgeInsets.all(AppConstants.space16),
      decoration: BoxDecoration(
        color: AppConstants.surfaceColor,
        borderRadius: BorderRadius.circular(AppConstants.space12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline_rounded, size: 16, color: AppConstants.primaryColor),
              const SizedBox(width: 8),
              Text(
                '${_selectedMode.name.toUpperCase()} CONFIGURATION',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: AppConstants.space16),
          switch (_selectedMode) {
            ConnectionMode.local => _buildLocalFields(),
            ConnectionMode.relay => _buildRelayFields(),
            ConnectionMode.cloud => _buildCloudFields(),
          },
        ],
      ),
    );
  }

  Widget _buildLocalFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _isScanning ? null : _scanMdns,
                icon: _isScanning
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.search_rounded, size: 18),
                label: Text(_isScanning ? 'SCANNING...' : 'SCAN LOCAL NETWORK'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          ],
        ),
        if (_scannedIp != null) ...[
          const SizedBox(height: AppConstants.space8),
          Center(
            child: Text(
              _scannedIp!.startsWith('Scan') ? _scannedIp! : 'Found: $_scannedIp',
              style: TextStyle(
                color: _scannedIp!.startsWith('Scan') ? AppConstants.errorColor : AppConstants.successColor,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
        const SizedBox(height: AppConstants.space16),
        TextField(
          controller: _localIpController,
          decoration: const InputDecoration(
            labelText: 'IP Address',
            hintText: '192.168.x.x',
          ),
        ),
        const SizedBox(height: AppConstants.space12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _localPortController,
                decoration: const InputDecoration(
                  labelText: 'WS Port',
                ),
                keyboardType: TextInputType.number,
                onChanged: (v) =>
                    setState(() => _localPort = int.tryParse(v) ?? 8766),
              ),
            ),
            const SizedBox(width: AppConstants.space12),
            Expanded(
              child: TextField(
                controller: _apiPortController,
                decoration: const InputDecoration(
                  labelText: 'API Port',
                ),
                keyboardType: TextInputType.number,
                onChanged: (v) => setState(() => _apiPort = int.tryParse(v) ?? 8000),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildRelayFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _userIdController,
          decoration: const InputDecoration(
            labelText: 'User ID (Must match Mac)',
            prefixIcon: Icon(Icons.person_outline_rounded, size: 18),
            hintText: 'user_123456',
          ),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: AppConstants.space12),
        TextField(
          controller: _relayHostController,
          decoration: const InputDecoration(
            labelText: 'Relay Host',
            hintText: 'mybot.siliconpulse.cc',
          ),
        ),
        const SizedBox(height: AppConstants.space12),
        TextField(
          controller: _relayPortController,
          decoration: const InputDecoration(
            labelText: 'Relay Port',
          ),
          keyboardType: TextInputType.number,
          onChanged: (v) =>
              setState(() => _relayPort = int.tryParse(v) ?? 8766),
        ),
        const SizedBox(height: AppConstants.space12),
        TextField(
          controller: _relayTokenController,
          decoration: const InputDecoration(
            labelText: 'Access Token',
            prefixIcon: Icon(Icons.key_rounded, size: 18),
          ),
          obscureText: true,
        ),
      ],
    );
  }

  Widget _buildCloudFields() {
    return TextField(
      controller: _cloudUrlController,
      decoration: const InputDecoration(
        labelText: 'Cloud WebSocket URL',
        hintText: 'ws://host:port/direct',
      ),
    );
  }

  Widget _buildSystemAgentFields() {
    return Container(
      padding: const EdgeInsets.all(AppConstants.space16),
      decoration: BoxDecoration(
        color: AppConstants.surfaceColor,
        borderRadius: BorderRadius.circular(AppConstants.space12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _systemBaseUrlController,
            decoration: const InputDecoration(
              labelText: 'API Base URL',
              hintText: 'https://api.openai.com/v1',
            ),
          ),
          const SizedBox(height: AppConstants.space12),
          TextField(
            controller: _systemApiKeyController,
            decoration: const InputDecoration(
              labelText: 'API Key',
              prefixIcon: Icon(Icons.vpn_key_rounded, size: 18),
            ),
            obscureText: true,
          ),
          const SizedBox(height: AppConstants.space12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _summaryModelController,
                  decoration: const InputDecoration(
                    labelText: 'Summary Model',
                  ),
                ),
              ),
              const SizedBox(width: AppConstants.space12),
              Expanded(
                child: TextField(
                  controller: _embeddingModelController,
                  decoration: const InputDecoration(
                    labelText: 'Embedding Model',
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionStatus() {
    return Container(
      padding: const EdgeInsets.all(AppConstants.space12),
      decoration: BoxDecoration(
        color: _getStatusColor().withOpacity(0.05),
        borderRadius: BorderRadius.circular(AppConstants.space8),
        border: Border.all(color: _getStatusColor().withOpacity(0.2)),
      ),
      child: Row(
        children: [
          Icon(Icons.circle, size: 10, color: _getStatusColor()),
          const SizedBox(width: AppConstants.space12),
          Expanded(
            child: Text(
              _connectionStatus.toUpperCase(),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: _getStatusColor(),
                letterSpacing: 0.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
