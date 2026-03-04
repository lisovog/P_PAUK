<img width="1447" height="609" alt="image" src="https://github.com/user-attachments/assets/c03c54c7-ef56-4765-93e9-a9a310dbf4b9" /># MISHKA Device Setup Guide

This guide will help you prepare your Raspberry Pi device for MISHKA deployment using a Windows PC.

---

## Step 1: Download Raspberry Pi Imager

Download and install **Raspberry Pi Imager** on your Windows PC:

**Download link:** https://www.raspberrypi.com/software/

<img width="1036" height="736" alt="image" src="https://github.com/user-attachments/assets/ab510b23-c4f5-4876-9a6f-a995ac48d721" />


---

## Step 2: Insert SD Card

Once Raspberry Pi Imager is installed, insert your **microSD card** into your computer (use a card reader if needed).

---

## Step 3: Open Raspberry Pi Imager and Select Device

1. Launch **Raspberry Pi Imager** on your PC.
2. Click **"Choose Device"**.
3. Select **Raspberry Pi 5** from the list.
4. Click **"Next"**.

---

## Step 4: Choose Operating System

1. Click **"Choose OS"**.
2. Select **"Raspberry Pi OS (other)"**.
3. Select **"Raspberry Pi OS Lite (64-bit)"** from the list.
4. Click **"Next"**.

<img width="1040" height="734" alt="image" src="https://github.com/user-attachments/assets/cb2f891f-c11d-4e61-ac04-00342f15c35d" />


---

## Step 5: Select Your SD Card

1. Click **"Choose Storage"**.
2. Select your SD card from the list (check the size to confirm it's correct).
3. Ensure **"Exclude system drives"** is checked.
4. Click **"Next"**.

---

## Step 6: Customisation - General Settings

The customisation screen will appear. Configure the following settings:

### Hostname
- Set hostname to: **PAUK_DEFAULT**

### Localisation
- **Capital City:** Canberra
- **Time Zone:** Australia/Sydney
- **Keyboard Layout:** au

Click **"Next"** when done.

---

## Step 7: Customisation - User Account

Set up the user account:

- **Username:** timeline
- **Password:** 1245
- **Confirm password:** 1245

Click **"Next"**.

---

## Step 8: Customisation - Wi-Fi

Configure the Wi-Fi connection:

- **SSID:** TL_SERVICE
- **Password:** tl_iot_service
- **Confirm password:** tl_iot_service

Click **"Next"**.

---

## Step 9: Customisation - SSH and Remote Access

Configure SSH access:

- **Enable SSH:** ✅ (ON)
- **Authentication mechanism:** Use password authentication
- **Enable Raspberry Pi Connect:** ❌ (OFF)

Click **"Next"**.

<img width="1039" height="739" alt="image" src="https://github.com/user-attachments/assets/61cae3d9-e369-452e-9f9d-a884aa40efea" />


---

## Step 10: Write to SD Card

1. Click **"Write"**.
2. When prompted, confirm by clicking **"Yes"** on the warning: _"All existing data on the storage device will be erased. Are you sure you want to continue?"_
3. Wait for the write process to complete (this may take several minutes).
4. Once finished, safely eject the SD card from your computer.

<img width="1037" height="738" alt="image" src="https://github.com/user-attachments/assets/0d2062ac-e1fe-4207-9756-eaa817acfe32" />

---

## Step 11: Insert SD Card into Raspberry Pi 5

1. Once the imaging process is complete, **safely eject** the SD card from your PC.
2. Insert the SD card into the **Raspberry Pi 5** device (SD card slot is on the underside).

---

## Step 12: Power On the Device

1. Connect the power supply to the Raspberry Pi 5.
2. If already connected, **unplug and plug back** the power cable to restart the device.
3. Wait approximately **2-3 minutes** for the device to boot up and connect to the Wi-Fi network.

---

## Step 13: Connect Your PC to the Same Network

Ensure your Windows PC is connected to the **same network** as the Raspberry Pi device.

- You can connect to the same Wi-Fi network (**TL_SERVICE**) that you configured for the device, **OR**
- Connect to a different SSID on the same network (if your router has multiple Wi-Fi networks).

<img width="1552" height="550" alt="image" src="https://github.com/user-attachments/assets/937705fe-7c59-4e64-90e4-6b9853594c15" />

---

## Step 14: Open Terminal

On your Windows PC, open **Windows Terminal** or **Command Prompt**.

---

## Step 15: Connect to the Device via SSH

1. In the terminal, type the following command (replace `IP_ADDRESS` with your device's IP address):

```
ssh timeline@IP_ADDRESS
```

2. When prompted **"Are you sure you want to continue connecting?"**, type `yes` and press **Enter**.

3. When prompted for a password, type `1245` and press **Enter**.

<img width="1447" height="609" alt="image" src="https://github.com/user-attachments/assets/430123fb-9142-4a54-ba6d-b7b09cb0d71a" />

---

## Step 16: Run MISHKA Installation

Run the following command to install MISHKA:

```bash
curl -fsSL https://raw.githubusercontent.com/lisovog/P_PAUK/stable/Deployment_Doc/install-new.sh | bash -s -- stable
```

This process will take several minutes. Wait for the installation to complete.

---

## Step 17: Confirm Installation and Open Web UI

Once the installation finishes, this is what a complete setup should look like.

1. Confirm all services show as running and healthy.
2. Verify the device appears online and is reporting data.
3. Click the third bullet point to open the device Web UI in your browser.
    - Example: http://192.168.3.105:8000 (use your device IP address)

After restarting the device, you can also open the Web UI using the device name:

http://PAUK-08B1CA.local:8000 (you will have a different device name based on the hostname you set during imaging, but it will follow the format: `hostname.local`)

<img width="1935" height="616" alt="image" src="https://github.com/user-attachments/assets/41bc0ce0-ae6f-4cb9-a9ac-7e95b6be7a84" />


---

## Updating to a New Version

When a new MISHKA release is available, update your device by following these steps:

### Step 1: Connect to the Device via SSH

```
ssh timeline@IP_ADDRESS
```

Password: `1245`

### Step 2: Run the Update

```bash
cd ~/mishka
bash Deployment_Doc/update.sh
```

This will:
- Stop all running services
- Download the latest configuration and database migrations
- Pull the latest Docker images
- Restart all services

The update takes approximately **5-10 minutes**. Wait for it to complete.

### Step 3: Verify the Update

After the update finishes, confirm everything is running:

```bash
cd ~/mishka && docker compose ps
```

All services should show **"Up"** status. Open the Web UI to verify:

http://YOUR_DEVICE_NAME.local:8000

---
