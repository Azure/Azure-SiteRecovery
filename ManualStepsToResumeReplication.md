# Announcement

For customers whose replication is impacted due to issue with tracking id 5NFG-PXG, please follow the steps below to avoid replication breakage and ensure uninterrupted ASR functionality:

# Execution Details

When the replication of the VM is critical, to resume the replication in Azure to Azure scenario, please follow the below steps. The steps involve stopping the mobility agent, removing a protection state file and starting mobility agent.


1. Linux
> Login to the replicating VM as root user
> Stop the mobility agent service
  ```sh
  /usr/local/ASR/Vx/bin/stop
  ```
> Remove RcmProtectionState.json file
  ```sh
   rm /usr/local/ASR/Vx/etc/RcmProtectionState.json 
  ```
> Start the moblity agent service
 Start the service using the command:
  ```sh
  /usr/local/ASR/Vx/bin/start
  ```
  
2. Windows
> Login to the replicating VM with administrator account

> Open a command prompt with administrator privileges

> Stop the mobility agent service
  ```
  sc stop svagents
  ```
> Remove RcmProtectionState.json file
   ```
  cd "C:\Program Files (x86)\Microsoft Azure Site Recovery\agent\Application Data\etc"
  del RcmProtectionState.json
  ```
> Start the mobility agent service
  ```
  sc start svagents
  ```
