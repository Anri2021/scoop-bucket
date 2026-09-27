# Anri's Scoop Bucket

Personal Scoop bucket for custom tools and utilities.

## How to use

```powershell
scoop bucket add anri https://github.com/Anri2021/scoop-bucket
scoop install ddns-dynu
```

## Meta-Bucket engine

The deterministic v4 pipeline resolves versions first, builds each changed cloud package on a separate runner, publishes verified ZIP assets in parallel, and skips unchanged fingerprints. ZIP is intentional: Scoop can extract it with Windows' native extractor when its optional 7-Zip helper is unavailable.
