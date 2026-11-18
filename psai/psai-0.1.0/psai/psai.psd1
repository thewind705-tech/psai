@{
    RootModule        = 'psai.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '438a75ac-5d78-4746-bcc3-bd3209805fc6'
    Author            = 'thewind705-tech'
    Description       = 'An AI assistant for PowerShell that runs on your local Ollama or LM Studio models: one-shot commands, chat, and a coding agent.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Invoke-Psai')
    AliasesToExport   = @('psai')
    CmdletsToExport   = @()
    VariablesToExport = @()
}
