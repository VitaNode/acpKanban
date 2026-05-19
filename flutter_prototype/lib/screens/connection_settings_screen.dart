import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/connection_config.dart';
import '../services/connection_config_manager.dart';
import '../services/smart_connect.dart';
import '../services/acp_client.dart';
import '../services/project_service.dart';
import '../constants/app_constants.dart';
import '../constants/ui_copy.dart';
import '../constants/error_copy.dart';
import '../theme/app_theme.dart';
import '../widgets/app_feedback.dart';

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
  State<ConnectionSettingsView> createState() => _ConnectionSettingsViewState();
}

class _ConnectionSettingsViewState extends State<ConnectionSettingsView> {
  late ConnectionMode _selectedMode;
  final ProjectService _projectService = ProjectService();
  late TextEditingController _localIpController;
  late TextEditingController _relayHostController;
  late TextEditingController _relayTokenController;
  late TextEditingController _apiTokenController;
  late TextEditingController _userIdController;
  late TextEditingController _localPortController;
  late TextEditingController _relayPortController;
  late TextEditingController _systemBaseUrlController;
  late TextEditingController _systemApiKeyController;
  late TextEditingController _summaryModelController;
  late TextEditingController _embeddingModelController;

  late int _relayPort;
  late int _localPort;

  bool _isConnecting = false;
  String _connectionStatus = UICopy.disconnected;
  bool _isScanning = false;
  String? _scannedIp;

  @override
  void initState() {
    super.initState();
    _selectedMode = widget.currentMode;
    _localIpController = TextEditingController();
    _relayHostController = TextEditingController();
    _relayTokenController = TextEditingController();
    _apiTokenController = TextEditingController();
    _userIdController = TextEditingController(text: widget.userId);
    _localPortController = TextEditingController(text: '8766');
    _relayPortController = TextEditingController(text: '8766');
    _systemBaseUrlController = TextEditingController();
    _systemApiKeyController = TextEditingController();
    _summaryModelController = TextEditingController(text: 'gpt-4o-mini');
    _embeddingModelController =
        TextEditingController(text: 'text-embedding-3-small');
    _relayPort = 8766;
    _localPort = 8766;
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final configManager = await ConnectionConfigManager.getInstance();
    final config = await configManager.loadConfig();
    if (!mounted) return;
    setState(() {
      _selectedMode = config.preferredMode;
      _localIpController.text = config.localIp ?? '';
      _relayHostController.text = config.relayHost ?? '';
      _relayTokenController.text = config.relayToken ?? '';
      _apiTokenController.text = config.apiToken ?? '';
      _userIdController.text = (config.userId == null || config.userId!.isEmpty)
          ? widget.userId
          : config.userId!;
      _localPortController.text = (config.localPort ?? 8766).toString();
      _relayPortController.text = (config.relayPort ?? 8766).toString();

      _systemBaseUrlController.text = config.systemConfig?.baseUrl ?? '';
      _systemApiKeyController.text = config.systemConfig?.apiKey ?? '';
      if (config.systemConfig != null) {
        _summaryModelController.text = config.systemConfig!.summaryModel ?? '';
        _embeddingModelController.text =
            config.systemConfig!.embeddingModel ?? '';
      }

      _relayPort = config.relayPort ?? 8766;
      _localPort = config.localPort ?? 8766;
    });
  }

  @override
  void dispose() {
    _localIpController.dispose();
    _relayHostController.dispose();
    _userIdController.dispose();
    _relayTokenController.dispose();
    _apiTokenController.dispose();
    _localPortController.dispose();
    _relayPortController.dispose();
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
          _scannedIp = UICopy.scanFailed;
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
      relayHost:
          _relayHostController.text.isEmpty ? null : _relayHostController.text,
      relayPort: _relayPort,
      relayToken: _relayTokenController.text.isEmpty
          ? null
          : _relayTokenController.text,
      apiToken:
          _apiTokenController.text.isEmpty ? null : _apiTokenController.text,
      userId: _userIdController.text.isEmpty ? null : _userIdController.text,
      useMdns: true,
      systemConfig: SystemProxyConfig(
        providerId: 'openai', // Default to openai for system tasks
        baseUrl: _systemBaseUrlController.text,
        apiKey: _systemApiKeyController.text,
        summaryModel: _summaryModelController.text,
        embeddingModel: _embeddingModelController.text,
        config: {
          'base_url': _systemBaseUrlController.text,
          'api_key': _systemApiKeyController.text,
          'summary_model': _summaryModelController.text,
          'embedding_model': _embeddingModelController.text,
        },
      ),    );

    await configManager.saveConfig(config);

    if (mounted) {
      setState(() {
        _isConnecting = true;
        _connectionStatus = UICopy.connecting;
      });
    }

    try {
      widget.acpClient.disconnect();

      final acpConfig = ACPConfig.fromConnectionConfig(
          config, config.userId ?? widget.userId);
      await widget.acpClient.smartConnect(acpConfig);
      await widget.acpClient.initialize(acpConfig.systemConfig);

      if (mounted) {
        setState(() {
          _connectionStatus = UICopy.connected;
        });

        widget.onConnectionChanged?.call(
          widget.acpClient.activeMode,
          widget.acpClient.activeUrl,
        );

        // Phase 5.5: Push system config to server to keep it in sync
        if (config.systemConfig != null) {
          _projectService.updateSystemConfig(config.systemConfig!);
        }

        AppFeedback.showSuccess(context, UICopy.connectedSuccessfully);      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _connectionStatus = '${UICopy.error}: ${e.toString()}';
        });
        AppFeedback.showError(context, ErrorCopy.mapError(null, e.toString()));
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
    if (_connectionStatus == UICopy.connected) return customColors.success!;
    if (_connectionStatus.startsWith(UICopy.error))
      return Theme.of(context).colorScheme.error;
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
            UICopy.connectionSettings,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.primary,
                ),
          ),
          const SizedBox(height: AppConstants.space24),
          _buildGuidanceCard(),
          const SizedBox(height: AppConstants.space32),
          Text(
            UICopy.unifiedCredentials,
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: AppConstants.space12),
          _buildUnifiedCredentialsFields(),
          const SizedBox(height: AppConstants.space32),
          Text(
            UICopy.connectionMode,
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const SizedBox(height: AppConstants.space12),
          _buildModeSelector(),
          const SizedBox(height: AppConstants.space24),
          _buildModeSpecificFields(),
          const SizedBox(height: AppConstants.space32),
          Text(
            UICopy.systemAgent,
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
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.power_settings_new_rounded),
              label:
                  Text(_isConnecting ? UICopy.scanning : UICopy.saveAndConnect),
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primary,
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
                padding:
                    const EdgeInsets.symmetric(vertical: AppConstants.space16),
                shape: RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.circular(AppConstants.radiusSmall)),
              ),
            ),
          ),
          const SizedBox(height: AppConstants.space32),
        ],
      ),
    );
  }

  Widget _buildUnifiedCredentialsFields() {
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
            controller: _userIdController,
            decoration: const InputDecoration(
              labelText: UICopy.userIdMatch,
              prefixIcon: Icon(Icons.person_outline_rounded, size: 18),
              hintText: 'user_123456',
            ),
          ),
          const SizedBox(height: AppConstants.space12),
          TextField(
            controller: _relayTokenController,
            decoration: const InputDecoration(
              labelText: UICopy.accessToken,
              prefixIcon: Icon(Icons.vpn_key_rounded, size: 18),
            ),
            obscureText: true,
          ),
          const SizedBox(height: AppConstants.space12),
          TextField(
            controller: _apiTokenController,
            decoration: const InputDecoration(
              labelText: UICopy.apiToken,
              prefixIcon: Icon(Icons.security_rounded, size: 18),
            ),
            obscureText: true,
          ),
        ],
      ),
    );
  }

  Widget _buildGuidanceCard() {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(AppConstants.space16),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withOpacity(0.1),
        borderRadius: BorderRadius.circular(AppConstants.radiusMedium),
        border: Border.all(color: colorScheme.primary.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.help_outline_rounded,
                  color: colorScheme.primary, size: 20),
              const SizedBox(width: 8),
              Text(
                UICopy.howToGetCredentials,
                style: TextStyle(
                  color: colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppConstants.space12),
          const Text(
            UICopy.credentialsGuide,
            style: TextStyle(fontSize: 13, height: 1.5),
          ),
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
          label: UICopy.local,
        ),
        const SizedBox(width: AppConstants.space8),
        _buildModeButton(
          mode: ConnectionMode.relay,
          icon: Icons.cloud_sync_rounded,
          label: UICopy.relay,
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
                color: isSelected
                    ? colorScheme.primary
                    : theme.dividerTheme.color!,
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
                    fontWeight:
                        isSelected ? FontWeight.bold : FontWeight.normal,
                    color: isSelected
                        ? colorScheme.primary
                        : theme.textTheme.bodyMedium?.color
                            ?.withOpacity(AppConstants.mediumEmphasis),
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
              Icon(Icons.info_outline_rounded,
                  size: 16, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                '${_selectedMode.name.toUpperCase()} ${UICopy.configuration}',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ],
          ),
          const SizedBox(height: AppConstants.space16),
          switch (_selectedMode) {
            ConnectionMode.local => _buildLocalFields(),
            ConnectionMode.relay => _buildRelayFields(),
            _ => _buildRelayFields(),
          },
        ],
      ),
    );
  }

  Widget _buildLocalFields() {
    final customColors = Theme.of(context).extension<CustomColors>()!;
    final isMac = !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

    if (isMac) {
      _localIpController.text = 'localhost';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!isMac) ...[
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
                  label: Text(
                      _isScanning ? UICopy.scanning : UICopy.scanLocalNetwork),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius:
                            BorderRadius.circular(AppConstants.radiusSmall)),
                  ),
                ),
              ),
            ],
          ),
          if (_scannedIp != null) ...[
            const SizedBox(height: AppConstants.space8),
            Center(
              child: Text(
                _scannedIp!.startsWith('Scan')
                    ? _scannedIp!
                    : '${UICopy.found}: $_scannedIp',
                style: TextStyle(
                  color: _scannedIp!.startsWith('Scan')
                      ? Theme.of(context).colorScheme.error
                      : customColors.success,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
          const SizedBox(height: AppConstants.space16),
        ],
        TextField(
          controller: _localIpController,
          enabled: !isMac,
          decoration: InputDecoration(
            labelText: isMac ? UICopy.localHostOnly : UICopy.ipAddress,
            hintText: UICopy.enterLanIp,
          ),
        ),
        const SizedBox(height: AppConstants.space12),
        TextField(
          controller: _localPortController,
          decoration: const InputDecoration(
            labelText: UICopy.wsPort,
          ),
          keyboardType: TextInputType.number,
          onChanged: (v) =>
              setState(() => _localPort = int.tryParse(v) ?? 8766),
        ),
      ],
    );
  }

  Widget _buildRelayFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _relayHostController,
          decoration: const InputDecoration(
            labelText: UICopy.relayHost,
            hintText: UICopy.enterCloudUrl,
          ),
        ),
        const SizedBox(height: AppConstants.space12),
        TextField(
          controller: _relayPortController,
          decoration: const InputDecoration(
            labelText: UICopy.relayPort,
          ),
          keyboardType: TextInputType.number,
          onChanged: (v) =>
              setState(() => _relayPort = int.tryParse(v) ?? 8766),
        ),
      ],
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
              labelText: UICopy.apiBaseUrl,
              hintText: 'https://api.openai.com/v1',
            ),
          ),
          const SizedBox(height: AppConstants.space12),
          TextField(
            controller: _systemApiKeyController,
            decoration: const InputDecoration(
              labelText: UICopy.apiKey,
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
                    labelText: UICopy.summaryModel,
                  ),
                ),
              ),
              const SizedBox(width: AppConstants.space12),
              Expanded(
                child: TextField(
                  controller: _embeddingModelController,
                  decoration: const InputDecoration(
                    labelText: UICopy.embeddingModel,
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
}
