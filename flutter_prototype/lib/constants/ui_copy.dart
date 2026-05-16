class UICopy {
  // Common
  static const String cancel = 'Cancel';
  static const String delete = 'Delete';
  static const String save = 'Save';
  static const String create = 'Create';
  static const String retry = 'Retry';
  static const String close = 'Close';
  static const String ok = 'OK';
  static const String loading = 'Loading...';

  // Board / Navigation
  static const String appTitle = 'AI Kanban';
  static const String board = 'Board';
  static const String roadmap = 'Roadmap';
  static const String timeline = 'Timeline';
  static const String connection = 'Connection';
  static const String switchProject = 'Switch Project';
  static const String selectProject = 'Select Project';
  static const String newProject = 'New Project';
  static const String manageProjects = 'Manage Projects...';
  static const String lastActive = 'Last active';
  static const String enterProjectName = 'Please enter a project name';
  static const String projectName = 'Project Name';
  static const String projectDescription = 'Project Description';
  static const String briefDescription = 'Brief description...';
  static const String workspacePath = 'Workspace Path';
  static const String descriptionHint = '💡 Description is included in the AI context.';
  static const String noProjectSelected = 'No project selected';
  static const String createProject = 'Create Project';
  static const String noColumnsFound = 'No columns found for this project.';

  static const String manageProjectsTitle = 'Manage Projects';
  static const String noProjectsAvailable = 'No projects available.';
  static const String editProject = 'Edit Project';
  static const String deleteProject = 'Delete Project';
  static const String deleteProjectTitle = 'Delete Project?';
  static const String confirmDeleteProjectMsg = 'Are you sure you want to delete';
  static const String cannotDeleteActiveMsg = 'Cannot delete active project';
  static const String deleteWarning = 'This action cannot be undone and will delete all cards, columns, and history associated with this project.';
  static const String confirmDeleteHint = 'Type project name to confirm';
  static const String deletePermanently = 'Delete Permanently';
  static const String saveChanges = 'Save Changes';
  static const String noWorkspacePath = 'No workspace path set';
  static const String created = 'Created';
  static const String cards = 'Cards';
  static const String workspace = 'Workspace';

  // Card Management
  static const String addCard = 'Add Card';
  static const String editCard = 'Edit Card';
  static const String deleteCard = 'Delete Card';
  static const String titleRequired = 'Title is required';
  static const String moveCard = 'Move to Column';
  static const String cardNotFound = 'Card not found in current project view';
  static const String confirmDeleteCard = 'Are you sure you want to delete this card?';
  static const String cardCompleted = 'Card completed';
  static const String cardReactivated = 'Card reactivated';
  static const String cardDeleted = 'Card deleted';
  static const String complete = 'Complete';
  static const String reactivate = 'Reactivate';
  static const String sessionReady = 'Session ready. Manual context only.';
  static const String failedToSave = 'Failed to save';
  static const String failedToLoadRoadmap = 'Error loading roadmap data';
  static const String failedToLoadProject = 'Error loading project info';
  static const String failedToLoadColumn = 'Error loading column info';
  static const String failedToLoadSummary = 'Error loading summary';
  static const String failedToLoadProvider = 'Error loading provider info';
  static const String agent = 'Agent';

  // Card Detail / Chat
  static const String startConversation = 'Start a conversation...';
  static const String agentThinking = 'Agent is thinking...';
  static const String stopAgent = 'Stop Agent';
  static const String confirmStopAgent = 'Are you sure you want to interrupt the agent?';
  static const String contextInjection = 'CONTEXT INJECTION';
  static const String progressSummary = 'PROGRESS SUMMARY';
  static const String sendToAgent = 'SEND TO AGENT';
  static const String summaryGenerated = 'Summary generated successfully!';
  static const String details = 'Details:';
  static const String milestone = 'Milestone';
  static const String feature = 'Feature';
  static const String uncategorized = 'Uncategorized';
  static const String none = 'None';
  static const String thinkingProcess = 'Thinking Process';
  static const String you = 'YOU';
  static const String toolLog = 'TOOL LOG';
  static const String arguments = 'ARGUMENTS';
  static const String result = 'RESULT';
  static const String failedToLoadPlan = 'Failed to load plan';

  // Connection Settings
  static const String connectionSettings = 'Connection Settings';
  static const String connectedSuccessfully = 'Connected successfully!';
  static const String connectionFailed = 'Connection failed';
  static const String configureCredentials = 'Please configure your User ID and Token to continue.';
  static const String webLocalNotSupported = 'Local connection is not supported on Web. Please use Relay or Cloud mode.';

  // Column Management
  static const String manageColumns = 'Manage Columns';
  static const String addColumn = 'Add Column';
  static const String editColumn = 'Edit Column';
  static const String deleteColumn = 'Delete Column';
  static const String cannotDeleteLastColumn = 'Cannot delete the last column';
  static const String dragToReorder = 'DRAG TO REORDER';
  static const String columnName = 'Column Name';
  static const String defaultAiProvider = 'Default AI Provider';
  static const String noneManualSelection = 'None (Manual selection)';
  static const String promptTemplate = 'Prompt Template';
  static const String promptTemplateHint = 'Instructions for AI in this column...';
  static const String customPromptDescription = '💡 Custom prompt for cards in this column.';
  static const String targetColumn = 'Target Column';
  static const String selectTargetColumn = 'Select target column';
}
