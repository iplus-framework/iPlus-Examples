# SQL Server Setup

For flexibility and version management, we run Microsoft SQL Server in a Docker container, hosted inside a Linux System Container (LXC). 

> **Why LVM?** SQL Server on Linux requires `ext4` or `XFS` filesystems. It does not support `btrfs` (the default Incus storage driver). We create a dedicated LVM storage pool for the SQL database files.

## 1. Create Storage Pool

Create a dedicated LVM pool.

```yaml
# storage.yaml
name: data
description: For SQL-Server (XFS/ext4)
driver: lvm
config:
  lvm.thinpool_name: IncusThinPool
  lvm.vg_name: data
  size: 600GiB
  source: /var/lib/incus/disks/data.img
```
Apply: `incus storage create -f storage.yaml` (or via UI)

## 2. Create the SQL Container

We create an Ubuntu container (`gipDLVmSQL1`) and attach the storage.

```bash
# Launch container
sudo incus launch ubuntu:24.04 gipDLVmSQL1 -c security.nesting=true

# Add the dedicated data volume
sudo incus storage volume create data SQLData size=600GiB
sudo incus config device add gipDLVmSQL1 disk-device-1 disk pool=data source=SQLData path=/data

# Add shared folder (optional, for backups)
sudo incus config device add gipDLVmSQL1 disk-device-2 disk source=/home/damir/SHARED path=/SHARED
```

## 3. Install Docker & SQL Server

Log into the container:
```bash
sudo incus exec gipDLVmSQL1 bash
```

### Install Docker
Inside the container:
```bash
apt update && apt install docker.io -y
```

### Deploy SQL Server (Docker)
We use Docker to run specific versions of SQL Server (e.g., 2019, 2022) side-by-side using different ports or separate containers.

1.  **Prepare Directories:**
    ```bash
    mkdir -p /data/2019/data
    mkdir -p /data/2019/bak
    ```

2.  **Run Container:**
    ```bash
    docker run -e "ACCEPT_EULA=Y" -e "MSSQL_SA_PASSWORD=YourStrong!Passw0rd" \
       -p 1433:1433 --name sql2019 \
       -v /data/2019/data:/var/opt/mssql \
       -v /data/2019/bak:/var/backups \
       -d mcr.microsoft.com/mssql/server:2019-latest
    ```
3. **To automatically start a container**
    ```bash
    docker update --restart always sql2019
    ```

### Manage SQL Server

**Change SA Password (if needed):**
```bash
docker exec -it sql2019 /opt/mssql-tools18/bin/sqlcmd \
-C -S localhost,1433 -U sa \
 -P "OLD_PASSWORD" \
 -Q "ALTER LOGIN sa WITH PASSWORD='NEW_PASSWORD'"
```

**Stop/Start/Remove:**
```bash
docker stop sql2019
docker start sql2019
docker rm sql2019
```

With this setup, your SQL Server data resides on the fast, compatible LVM volume `/data`, while the engine runs effectively in a disposable Docker container.
