import 'package:flutter/material.dart';
import '../models/connection_config.dart';
import '../services/connection_config_manager.dart';
import '../services/smart_connect.dart';
import '../services/acp_client.dart';
import '../services/auth_service.dart';
import '../constants/app_constants.dart';
import '../theme/app_theme.dart';

class ConnectionSettingsView extends StatefulWidget {
  final ACPClient acpClient;
  final ConnectionMode currentMode;
  final String userId;
  final Function(ConnectionPath newMode, String? url)? onConnectionChanged;

  const ConnectionSettingsView({
    super.key,
    required this.acpClient,
    required this.currentMode,
    required this.userId,
    this.onConnectionChanged,
  });

  @override
  State<ConnectionSettingsView> createState() =>
      _ConnectionSettingsViewState();
}

class _ConnectionSettingsViewState extends State<ConnectionSettingsView> {
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
  bool _isPairing = false;

  final TextEditingController _pairingHostController = TextEditingController();
  final TextEditingController _pairingCodeController = TextEditingController();

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
    if (!mounted) return;
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
    _pairingHostController.dispose();
    _pairingCodeController.dispose();
    super.dispose();
  }

  Future<void> _startPairing() async {
    final host = _pairingHostController.text.trim();
    final code = _pairingCodeController.text.trim();

    if (host.isEmpty || code.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter both Host IP and Pairing Code')),
      );
      return;
    }

    setState(() => _isPairing = true);

    try {
      final result = await AuthService().pairWithCode(host, code);
      if (result.success && result.config != null) {
        await _loadConfig(); // Refresh UI with new config
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pairing successful! Settings updated.')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Pairing failed: ${result.message}')),
        );
      }
    } finally {
      if (mounted) setState(() => _isPairing = false);
    }
  }

  Future<void> _scanMdns() async {
    setState(() {
      _isScanning = true;
      _scannedIp = null;
    });

    try {
      final ip = await SmartConnect.discoverLocalMac();
      if (mounted) {
        setState(() {
          _scannedIp = ip;
          if (ip != null) {
            _localIpController.text = ip;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _scannedIp = 'Scan failed';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isScanning = false;
        });
      }
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

      final acpConfig = ACPConfig.fromConnectionConfig(config, config.userId ?? widget.userId);
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
    final customColors = Theme.of(context).extension<CustomColors>()!;
    if (_connectionStatus.startsWith('Connected')) return customColors.success!;
    if (_connectionStatus.startsWith('Failed')) return Theme.of(context).colorScheme.error;
    return customColors.warning!;
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppConstants.space16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'CONNECTION SETTINGS',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.primary,
                ),
          ),
          const SizedBox(height: AppConstants.space24),
          _buildPairingSection(),
          const SizedBox(height: AppConstants.space32),
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
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
                padding: const EdgeInsets.symmetric(vertical: AppConstants.space16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusSmall)),
              ),
            ),
          ),
          const SizedBox(height: AppConstants.space32),
        ],
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
    final colorScheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    
    return Expanded(
      child: Material(
        color: isSelected 
          ? colorScheme.primary.withOpacity(0.1) 
          : colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(AppConstants.radiusSmall),
        child: InkWell(
          onTap: () => setState(() => _selectedMode = mode),
          borderRadius: BorderRadius.circular(AppConstants.radiusSmall),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: AppConstants.space12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppConstants.radiusSmall),
              border: Border.all(
                color: isSelected ? colorScheme.primary : theme.dividerTheme.color!,
                width: isSelected ? 2 : 1,
              ),
            ),
            child: Column(
              children: [
                Icon(icon, 
                  color: isSelected 
                    ? colorScheme.primary 
                    : theme.textTheme.bodySmall?.color, 
                  size: 20),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    color: isSelected ? colorScheme.primary : theme.textTheme.bodyMedium?.color?.withOpacity(AppConstants.mediumEmphasis),
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
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
        border: Border.all(color: Theme.of(context).dividerTheme.color!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline_rounded, size: 16, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                '${_selectedMode.name.toUpperCase()} CONFIGURATION',
                style: Theme.of(context).textTheme.labelLarge,
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
    final customColors = Theme.of(context).extension<CustomColors>()!;
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
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusSmall)),
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
                color: _scannedIp!.startsWith('Scan') ? Theme.of(context).colorScheme.error : customColors.success,
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
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
        border: Border.all(color: Theme.of(context).dividerTheme.color!),
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
        borderRadius: BorderRadius.circular(AppConstants.radiusSmall),
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

  Widget _buildPairingSection() {
    return Container(
      padding: const EdgeInsets.all(AppConstants.space16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.1),
        borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
        border: Border.all(color: Theme.of(context).colorScheme.primary.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.phonelink_setup_rounded, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                'DEVICE PAIRING',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppConstants.space12),
          Text(
            'Enter the Host IP (e.g., Tailscale IP) and the 6-digit code shown on your Mac.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: AppConstants.space16),
          TextField(
            controller: _pairingHostController,
            decoration: const InputDecoration(
              labelText: 'Host IP Address',
              hintText: '100.x.x.x or 192.168.x.x',
              isDense: true,
            ),
          ),
          const SizedBox(height: AppConstants.space12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _pairingCodeController,
                  decoration: const InputDecoration(
                    labelText: '6-Digit Code',
                    hintText: '123456',
                    isDense: true,
                    counterText: '',
                  ),
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                ),
              ),
              const SizedBox(width: AppConstants.space12),
              ElevatedButton(
                onPressed: _isPairing ? null : _startPairing,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
                child: _isPairing
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('PAIR'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
