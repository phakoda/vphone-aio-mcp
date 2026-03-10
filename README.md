# vphone-aio
1 script run the vphone (iOS 26.1), already jailbroken with full bootstrap installed

Do this step by step:

1. Install prerequisites:
   ```bash
   brew install git-lfs wget zstd
   ```
2. Disable SIP, set `amfi_get_out_of_my_way=1`
3. Download or clone this repo (it might take a while, for me 12GB takes me 20 minutes to finish)
4. If any split parts are missing, the script will auto-download them. You can also manually download them:
   ```bash
   for p in aa ab ac ad ae af ag; do
     wget -O "vphone-cli.tar.zst.part_${p}" \
       "https://github.com/34306/vphone-aio/raw/refs/heads/main/vphone-cli.tar.zst.part_${p}?download="
   done
   ```
5. Pre-download/extract only if you want to stage the payload first:
   ```bash
   ./vphone-aio.sh --prepare
   ```
6. Run the full launcher when SIP is disabled and `amfi_get_out_of_my_way=1` is set:
   ```bash
   ./vphone-aio.sh
   ```
7. Wait until extraction finishes (about 15 minutes)
8. The launcher now extracts directly from the split files, so it does not create an extra merged `vphone-cli.tar.zst` on disk
9. The built-in Virtualization VNC server will print its URL/password and open automatically
10. You can remove `.git` once the extraction is done
11. Enjoy!

## MCP Server

An MCP server is included under [`vphone-cli`](./vphone-cli) so an AI client can boot the VM, capture screenshots, and inject touch gestures over MCP stdio.

Build, sign, and run it from the package directory:

```bash
cd vphone-cli
chmod +x mcp.sh
./mcp.sh
```

The server exposes these tools:

- `vphone_status`
- `vphone_start`
- `vphone_stop`
- `vphone_screenshot`
- `vphone_tap`
- `vphone_swipe`

Coordinates for `vphone_tap` and `vphone_swipe` are normalized: `(0,0)` is the top-left corner of the phone display and `(1,1)` is the bottom-right corner.

Example MCP client config:

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

`vphone_start` auto-discovers a local `VM/` directory when the server is launched from `vphone-cli`. This repo does not include `vphone-cli/VM` or guest state; provide your own VM assets locally, or pass `vm_dir` or explicit asset paths.

## SHA-256 Checksums

To verify your downloaded files are not corrupted:

```
3c966247deae3fff51a640f6204e0fafc14fd5c76353ba8f28f20f7d1d29e693  vphone-cli.tar.zst.part_aa
c7d11bbbe32dda2b337933c736171cc94faab2c7465e75391fa49029f3b6f1b1  vphone-cli.tar.zst.part_ab
f422949080e7f141f32f35f8ea20c1fedffc2b97eadf0390645114feef6bb1aa  vphone-cli.tar.zst.part_ac
f3acfa47145207b8962ba4d20fb83eb4646934cca768906e65609d7fdde564e7  vphone-cli.tar.zst.part_ad
efdca69df80386b0aa7af8ac260d9ac576ed1f258429fd4ac21b5bbb87cd78fe  vphone-cli.tar.zst.part_ae
4628852da12949361d3ea6efcf8af1532eb52194cc43a4ab4993024267947587  vphone-cli.tar.zst.part_af
8bd1551511eb016325918c2d93519829be04feb54727612e74c32e4299670a88  vphone-cli.tar.zst.part_ag
```

You can verify manually with:
```bash
shasum -a 256 vphone-cli.tar.zst.part_a*
```

# Preview
![](preview.png)

# Credits
- [wh1te4ver (Hyungyu Seo)](https://github.com/wh1te4ever) for a super details and writeup: https://github.com/wh1te4ever/super-tart-vphone-writeup

- [Lakr233](https://github.com/Lakr233) for [non-tart repo vphone (vphone-cli)](https://github.com/Lakr233/vphone-cli)
