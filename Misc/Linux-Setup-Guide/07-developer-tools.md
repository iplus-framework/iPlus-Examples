# Developer Tools Setup

## 1. Git Configuration

Handling Personal vs. Work identities correctly using Git.

### `.gitconfig` Structure
We use conditional includes to separate configuration based on the directory path or remote URL.

**`~/.gitconfig` (Global):**
```ini
[includeIf "hasconfig:remote.*.url:git@github.com:*/**"]
    path = ~/.gitservers/.gitconfig-github
[includeIf "hasconfig:remote.*.url:ssh://user@private-repo.com*/**"]
    path = ~/.gitservers/.gitconfig-work
```

**`~/.gitservers/.gitconfig-github`:**
```ini
[user]
    name = Damir Lisak
    email = public@example.com
```

**`~/.gitservers/.gitconfig-work`:**
```ini
[user]
    name = Damir Lisak
    email = work@example.com
```

### SSH Configuration (`~/.ssh/config`)
Automate key selection for different hosts.

1.  **Generate/Copy Keys:** Ensure permissions are strict (`chmod 600`).
2.  **Add to Agent:** `ssh-add ~/.ssh/id_rsa_work`
3.  **Config File:**

```ssh
# Work Server
Host private-repo.com
    HostName private-repo.com
    User git
    IdentityFile ~/.ssh/id_rsa_work
    AddKeysToAgent yes

# GitHub
Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_rsa_github
    AddKeysToAgent yes
```

## 2. VS Code & .NET

### Install .NET SDK
For native Linux development (Avalonia, Console, Web API):

```bash
sudo apt-get update && sudo apt-get install -y dotnet-sdk-8.0
# Or specific version like 6.0 / 9.0
```

### VS Code Extensions
Recommended extensions for .NET development:
*   **C# Dev Kit** (Microsoft)
*   **Avalonia for VSCode** (if doing UI work)
*   **Docker**
*   **Remote - SSH**

### NUGET
If you are experiencing problems with the NuGet V3 API in a Windows VM due to Incus NAT:

References:
*   [Nuget](https://github.com/NuGet/NuGetGallery/issues/10448)
*   [VS Community](https://developercommunity.visualstudio.com/t/Cant-connect-to-nuget-api/11001841?sort=active)

Switch Nuget API in Visual Studio Settings from [V3](https://api.nuget.org/v3/index.json) to [V2](https://nuget.org/api/v2) until this bug is fixed.

Another possible cause is the prioritization of IPv6 over IPv4. This order can be resolved as follows:

```bash
sudo vim /etc/gai.conf
Remove hashtag:
precedence ::ffff:0:0/96 100
systemctl restart systemd-networkd
```
References:
*   [VS Community](https://zomro.com/blog/faq/471-changing-priority-from-ipv6-to-ipv4-in-ubuntu-and-centos-a-complete-guide)

