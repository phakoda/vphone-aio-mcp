# vphone-aio

Boot a virtual iPhone on Apple's research virtualization stack, either interactively through the GUI/VNC path or programmatically through MCP.

This repo now contains two related pieces:

- `vphone-cli/`: the checked-in Swift package with the VM boot code and the MCP server.
- `vphone-aio.sh`: an optional convenience launcher for the original archive-based workflow.

## What This Repo Includes

- Swift sources for `vphone-cli`
- Swift sources for `vphone-mcp`
- build/sign helper scripts
- the original archive wrapper files and split archive metadata

## What This Repo Does Not Include

This repo does not include a safe-to-share guest VM state. You must provide your own local `vphone-cli/VM/` directory and firmware inputs.

Do not commit any of these:

- `vphone-cli/VM/`
- `vphone-cli/.build/`
- `vphone-cli/RemoteStuff.zip`
- any guest disk, NVRAM, SEP storage, serial logs, or personal data from a running VM

## Repository Layout

- `vphone-cli/`
  Source package with:
  - `vphone-cli`: interactive VM launcher
  - `vphone-mcp`: MCP stdio server for screenshots and touch input
- `vphone-aio.sh`
  Optional root helper that prepares and launches `vphone-cli`
- `vphone-cli/README.md`
  Detailed research/firmware preparation notes for building the VM inputs

## Host Requirements

- Apple Silicon Mac
- macOS 15+ with Xcode / Swift toolchain available
- SIP disabled
- research guest support enabled
- boot arg `amfi_get_out_of_my_way=1`
- `zstd`
- `wget`
- `git-lfs` if you want the original split archive workflow

Install the common tools:

```bash
brew install git-lfs wget zstd
```

## Security / Boot Requirements

The VM uses private Virtualization APIs and custom entitlements. The host must be configured before either `vphone-cli` or `vphone-mcp` can boot a guest.

Typical setup:

1. Reboot into Recovery.
2. Disable SIP:
   ```bash
   csrutil disable
   ```
3. Enable research guests:
   ```bash
   csrutil allow-research-guests enable
   ```
4. Boot back into macOS.
5. Set the required boot arg:
   ```bash
   sudo nvram boot-args="amfi_get_out_of_my_way=1 -v"
   ```
6. Reboot again.

The longer research/firmware workflow is documented in [vphone-cli/README.md](./vphone-cli/README.md).

## Clone Options

If you only want the source tree and MCP server, a metadata-only clone is usually the easiest path:

```bash
GIT_LFS_SKIP_SMUDGE=1 git clone https://github.com/phakoda/vphone-aio-mcp.git
cd vphone-aio-mcp
```

If you want the original split-archive workflow too:

```bash
git lfs install
git clone https://github.com/phakoda/vphone-aio-mcp.git
cd vphone-aio-mcp
```

If LFS checkout fails, you can still work from the checked-in `vphone-cli/` sources with `GIT_LFS_SKIP_SMUDGE=1`.

## Prepare VM Assets

Before booting anything, prepare a local `vphone-cli/VM/` directory. The fast summary is:

1. Create a PCC research VM template on the host.
2. Copy the required research VM files locally.
3. Download the IPSW / PCC firmware inputs.
4. Patch or prepare the firmware using the scripts described in [vphone-cli/README.md](./vphone-cli/README.md).
5. Place the resulting files under `vphone-cli/VM/`.

At minimum, the normal boot path expects these local files:

- `vphone-cli/VM/AVPBooter.vresearch1.bin`
- `vphone-cli/VM/AVPSEPBooter.vresearch1.bin`
- `vphone-cli/VM/Disk.img`
- `vphone-cli/VM/nvram.bin`
- `vphone-cli/VM/SEPStorage`

Additional files such as `machineIdentifier.bin`, `serial.log`, or other preparation artifacts may be created locally while you use the VM.

## Quick Start: GUI / VNC Boot

Once `vphone-cli/VM/` exists locally:

```bash
cd vphone-cli
./boot.sh
```

What `boot.sh` does:

- builds both `vphone-cli` and `vphone-mcp`
- signs the binaries with `vphone.entitlements`
- starts the VM with:
  - 16 CPU cores
  - 8192 MB memory
  - serial logging to `vphone-cli/VM/serial.log`
  - SEP enabled
  - built-in experimental VNC enabled

The VM window / built-in VNC details are printed during startup. Press `Ctrl+C` to stop the process if you launched it through the wrapper flow.

## MCP Server

The repo includes an MCP stdio server at `vphone-cli/Sources/vphone-mcp/`.

Launch it from the package directory:

```bash
cd vphone-cli
chmod +x mcp.sh
./mcp.sh
```

`mcp.sh` runs `build_and_sign.sh` first, then starts the signed `vphone-mcp` binary.

### Exposed Tools

- `vphone_status`
- `vphone_start`
- `vphone_stop`
- `vphone_screenshot`
- `vphone_tap`
- `vphone_swipe`

Touch coordinates are normalized:

- `(0, 0)` = top-left of the phone display
- `(1, 1)` = bottom-right of the phone display

### MCP VM Path Resolution

If you launch the server from `vphone-cli/`, `vphone_start` will auto-discover a local `./VM/` directory.

If your client runs the server from somewhere else, pass one of:

- `vm_dir`
- explicit `rom_path`
- explicit `disk_path`
- explicit `nvram_path`
- explicit `sep_rom_path`
- explicit `sep_storage_path`

### Generic MCP Client Example

```json
{
  "mcpServers": {
    "vphone": {
      "command": "/absolute/path/to/vphone-aio/vphone-cli/mcp.sh",
      "cwd": "/absolute/path/to/vphone-aio/vphone-cli"
    }
  }
}
```

### Codex Config Example

Add this to `~/.codex/config.toml`:

```toml
[mcp_servers.vphone]
command = "/absolute/path/to/vphone-aio/vphone-cli/mcp.sh"
cwd = "/absolute/path/to/vphone-aio/vphone-cli"
```

### MCP Usage Notes

- The first meaningful screenshot can take a while after `vphone_start`. In testing, the framebuffer stayed black for roughly the first 1 to 2 minutes after boot, then screenshots became usable once SpringBoard finished loading.
- If `vphone_start` fails because storage is already in use, another VM process is usually still holding the NVRAM / auxiliary storage files open.
- `vphone_screenshot`, `vphone_tap`, and `vphone_swipe` work against the in-process VM started by the MCP server. Start the VM through MCP, not through a separate launcher, if you want the MCP tools to control that same instance.

## Optional Root Wrapper Workflow

The root helper still exists:

```bash
./vphone-aio.sh --prepare
./vphone-aio.sh
```

Behavior:

- `--prepare`
  - downloads missing split archive parts if needed
  - extracts `vphone-cli/`
  - removes the archive parts afterward
- default run mode
  - checks SIP / boot args
  - extracts `vphone-cli/` if needed
  - changes into `vphone-cli/`
  - runs `./boot.sh`

If `vphone-cli/` already exists, extraction is skipped.

## Troubleshooting

### SIP or boot-arg errors

If the launcher says SIP is still enabled or `amfi_get_out_of_my_way=1` is missing, fix the host security configuration first. The binaries will not boot the guest correctly until that is done.

### Missing VM assets

If `vphone_start` or `boot.sh` complains about missing files, check that your local `vphone-cli/VM/` directory contains the expected ROM, disk, NVRAM, and SEP files.

### Black screenshots right after boot

This is expected early in the boot process. Wait longer, then retry `vphone_screenshot`.

### VM assets locked by another process

If startup reports that auxiliary storage or NVRAM is already in use, stop the other VM process first or point MCP at a different local NVRAM path.

### LFS clone problems

If cloning tries to download the old split archives and fails, clone with:

```bash
GIT_LFS_SKIP_SMUDGE=1 git clone https://github.com/phakoda/vphone-aio-mcp.git
```

You can still use the source-based `vphone-cli/` workflow without the LFS archive parts.

## Split Archive Checksums

These are the checksums for the original root split archives:

```text
3c966247deae3fff51a640f6204e0fafc14fd5c76353ba8f28f20f7d1d29e693  vphone-cli.tar.zst.part_aa
c7d11bbbe32dda2b337933c736171cc94faab2c7465e75391fa49029f3b6f1b1  vphone-cli.tar.zst.part_ab
f422949080e7f141f32f35f8ea20c1fedffc2b97eadf0390645114feef6bb1aa  vphone-cli.tar.zst.part_ac
f3acfa47145207b8962ba4d20fb83eb4646934cca768906e65609d7fdde564e7  vphone-cli.tar.zst.part_ad
efdca69df80386b0aa7af8ac260d9ac576ed1f258429fd4ac21b5bbb87cd78fe  vphone-cli.tar.zst.part_ae
4628852da12949361d3ea6efcf8af1532eb52194cc43a4ab4993024267947587  vphone-cli.tar.zst.part_af
8bd1551511eb016325918c2d93519829be04feb54727612e74c32e4299670a88  vphone-cli.tar.zst.part_ag
```

Manual verification:

```bash
shasum -a 256 vphone-cli.tar.zst.part_a*
```

## Preview

![](preview.png)

## Credits

- [wh1te4ver (Hyungyu Seo)](https://github.com/wh1te4ever) for the write-up and research notes: [super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
- [Lakr233](https://github.com/Lakr233) for the original [`vphone-cli`](https://github.com/Lakr233/vphone-cli)
