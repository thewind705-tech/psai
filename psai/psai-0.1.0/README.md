# psai

An AI assistant for PowerShell that runs on **your own computer**, using models from
[Ollama](https://ollama.com) or [LM Studio](https://lmstudio.ai). Nothing is sent to the cloud.

```
psai "find the 10 biggest files in this folder"   # suggests a command, you run or copy it
psai                                               # chat
psai /code                                         # coding agent for the current folder
```

Works on **Windows PowerShell 5.1** (built into Windows) and **PowerShell 7**.

## Install

1. Install Ollama or LM Studio and download a model (see [Which model?](#which-model)).
2. Unzip `psai.zip` anywhere, open PowerShell in that folder and run:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install.ps1
   ```

   The installer copies psai into your PowerShell modules folder. If Windows is set to block
   scripts, it offers to switch your user account to `RemoteSigned` (needed for any PowerShell
   module that isn't signed).
3. Open a **new** PowerShell window and type `psai`.

The first time, psai asks:

1. **Ollama or LM Studio?**
2. **The server URL.** Press Enter for the default (`http://localhost:11434` for Ollama,
   `http://localhost:1234` for LM Studio).
3. **Which model** to use, from the ones you've downloaded.
4. With Ollama: whether to **check that the model fits in your GPU memory**. If part of it
   spills onto the CPU, psai offers to lower the context size until it fits.

Run `psai /setup` any time to change these answers.

## Using it

### One-shot commands: `psai "..."`

```powershell
psai "show my IP address"
psai "rename all .jpeg files here to .jpg"
psai "which process is using port 8080"
```

psai answers with a command and asks: **[y] run, [c] copy, [n] no**. Commands that delete or
change things get a red warning first. After you run or copy a command, it's in your history:
press the Up arrow to edit it and run it again.

Put your request in quotes. Without them, PowerShell reads characters like `|`, `>`, `;`, `$`
and `(` itself, and turns `1GB` into `1073741824`.

### Chat: `psai`

Just `psai` starts a conversation that keeps going until you type `/exit`.

| Command   | What it does                    |
|-----------|---------------------------------|
| `/clear`  | start a new conversation        |
| `/model`  | switch to another model         |
| `/help`   | list commands                   |
| `/exit`   | leave                           |
| `Esc`     | stop the reply that's coming in |

Pasting several lines sends them as one message. You can also type `"""` on its own line,
write as many lines as you like, then type `"""` again to send them.

### Coding agent: `psai /code`

Go to your project folder and start the agent:

```powershell
cd C:\projects\my-app
psai /code
psai /code add a --verbose flag to the CLI     # or give the task right away
```

The agent has six tools: `list_files`, `read_file`, `search`, `write_file`, `edit_file` and
`run_command`. It reads files on its own, but it **asks before every file change and every
command**:

- `y` yes
- `n` no, and you can tell it what to do instead
- `a` yes to all file edits for the rest of this task (commands still ask)
- `s` stop the task

It can only touch files inside the folder you started it in. Commands run in a separate
PowerShell process in that folder, with a time limit (120 seconds by default), and you can press
Esc to stop one.

Changes keep each file's encoding and line endings. New `.ps1` files with non-English characters
are saved with a BOM so Windows PowerShell 5.1 reads them correctly.

### In VS Code

Run `psai /code` in VS Code's built-in terminal (`` Ctrl+` ``). psai notices it's inside
VS Code and:

- opens every proposed change as a **diff tab** (left: the file now, right: the proposed version)
  before you approve it,
- opens the file at the changed line after you approve it.

The `code` command must be available. It is by default when VS Code is installed on Windows.
To use the same model in VS Code's own AI features, point an extension that supports Ollama
(for example Continue or Cline, or Copilot Chat with a local model) at `http://localhost:11434`
and pick the same model. Ollama can serve psai and VS Code at the same time.

### Other commands

| Command          | What it does                                           |
|------------------|--------------------------------------------------------|
| `psai /explain`  | explains the last error in this PowerShell window      |
| `psai /model`    | pick another model                                     |
| `psai /status`   | shows the settings, checks the server and GPU use      |
| `psai /config`   | opens the settings file                                |
| `psai /setup`    | runs the first-time setup again                        |
| `psai /help`     | lists all commands                                     |

## Which model?

For an 8 GB graphics card, one model that handles all three modes:

```powershell
ollama pull qwen3.5:9b
```

About 6.6 GB at Q4_K_M, with tool calling (needed by `/code`). In LM Studio, search for
"qwen3.5 9b" and download a **Q4_K_M** file.

Keep in mind that a 9B model handles focused tasks well, like "add a parameter to this function"
or "write a script that does X". Large changes across many files are hard for a model this size.
Small, clear tasks give the best results.

Models without built-in tool calling still work with `/code`: psai notices and describes the
tools to the model as text instead.

### Speed and GPU memory

The model and its **context** (how much text it can keep in mind) both have to fit in GPU
memory. If they don't, part of the model runs on the CPU and everything gets several times
slower. Check with `psai /status`, or `ollama ps`, which should say `100% GPU`. If it doesn't,
lower `ContextLength` in `psai /config` (16384 → 8192).

With LM Studio, the context length is set in LM Studio when the model loads. Put the same
number in `ContextLength` so psai knows how much text fits.

## Settings

`psai /config` opens `%USERPROFILE%\.psai\config.json`:

| Setting              | Default     | What it does |
|----------------------|-------------|--------------|
| `Provider`           |             | `ollama` or `lmstudio` |
| `Url`                |             | server address |
| `Model`              |             | model name |
| `ApiKey`             | `""`        | only if your server needs one (sent as a Bearer token) |
| `ContextLength`      | `16384`     | context size in tokens. Ollama uses it directly; with LM Studio, match what LM Studio loads |
| `Temperature`        | `null`      | `null` uses the model's own default |
| `Think`              | `null`      | Ollama only: `false` turns off "thinking" for faster answers, `true` forces it, `null` = model default |
| `ShowThinking`       | `false`     | show the model's thinking in gray instead of a spinner |
| `DiffViewer`         | `"auto"`    | `auto` (VS Code diffs when inside VS Code), `vscode`, or `terminal` |
| `EditorCommand`      | `"code"`    | the editor's command, e.g. `code-insiders` or `cursor` |
| `OpenEditedFiles`    | `true`      | open changed files in the editor after you approve them |
| `CommandTimeoutSec`  | `120`       | time limit for commands the agent runs |
| `RequestTimeoutSec`  | `300`       | how long to wait for the model before giving up |
| `MaxToolOutputChars` | `12000`     | how much of a file or command output the agent sees at once |
| `MaxAgentSteps`      | `30`        | steps before the agent asks whether to keep going |

## Your own instructions

Put text files in `%USERPROFILE%\.psai` (the same folder as `config.json`) and psai adds
them to what it tells the model:

| File         | Used for                          |
|--------------|-----------------------------------|
| `prompt.md`  | every mode                        |
| `command.md` | one-shot commands (`psai "..."`)  |
| `chat.md`    | chat (`psai`)                     |
| `code.md`    | the coding agent (`psai /code`)   |
| `explain.md` | `psai /explain`                   |

To edit one, open it in Notepad from PowerShell. If the file doesn't exist yet, Notepad
asks whether to create it: click **Yes**.

```powershell
notepad "$HOME\.psai\prompt.md"    # every mode
notepad "$HOME\.psai\chat.md"      # only chat
notepad "$HOME\.psai\command.md"   # only psai "..."
notepad "$HOME\.psai\code.md"      # only psai /code
notepad "$HOME\.psai\explain.md"   # only psai /explain
```

Write plain instructions, one per line, for example "Always answer in Turkish" or "This
project uses Python 3.12 and pytest". Save with Ctrl+S. They're read each time psai starts,
so there's nothing to reload. Keep them short: they take up part of the model's context.
To remove your instructions, empty or delete the file.

## Troubleshooting

**"psai is not recognized"**: open a new PowerShell window after installing. If it still isn't
found, run `Import-Module psai` and read the error message.

**"running scripts is disabled on this system"**: run
`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`, or run the installer again.

**"Can't connect to http://localhost:11434"**: Ollama isn't running. Start it from the Start
menu, or run `ollama serve`. For LM Studio, open the **Developer** tab and switch the server on.

**Slow answers**: see [Speed and GPU memory](#speed-and-gpu-memory). The first answer after a
while is also slower because the model has to load.

**"does not support tools"**: psai switches to its text-based tool format automatically. For best
results in `/code`, use a model with tool support, such as `qwen3.5:9b`.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1
```

## Files

```
install.ps1          installer
uninstall.ps1        uninstaller
psai/psai.psd1       module manifest
psai/psai.psm1       entry point (the psai command)
psai/src/Config.ps1  settings, setup, model list, GPU check
psai/src/Http.ps1    streaming HTTP, spinner, Esc handling
psai/src/Model.ps1   Ollama / LM Studio requests and reply parsing
psai/src/Ui.ps1      terminal output, prompts, diffs
psai/src/Chat.ps1    one-shot commands, chat, /explain
psai/src/Agent.ps1   /code agent and its tools
psai/src/Json.ps1    JSON writer that behaves the same on 5.1 and 7
```