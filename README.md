# Scoop 极客仓

<!-- Uncomment the following line after replacing placeholders -->
[![Tests](https://github.com/scoop-plus/geeks/actions/workflows/ci.yml/badge.svg)](https://github.com/scoop-plus/geeks/actions/workflows/ci.yml) [![Excavator](https://github.com/scoop-plus/geeks/actions/workflows/excavator.yml/badge.svg)](https://github.com/scoop-plus/geeks/actions/workflows/excavator.yml)

Geeks bucket for [Scoop](https://github.com/ScoopInstaller/Scoop)

## 食用方法

```powershell
scoop bucket add geeks https://github.com/scoop-plus/geeks
scoop install geeks/aria2
```


### Make a new manifests

To make a new manifest, see
[App Manifests](https://github.com/ScoopInstaller/Scoop/wiki/App-Manifests)
wiki page.


### Get filehash
```powershell
Get-FileHash -Algorithm SHA256 -Path <your download file>
```

### Auto Update
```powershell
.\bin\checkver.ps1 -Update
```

### Auto Pr
```powershell
.\bin\auto-pr.ps1 -p
```
