# OpenWrt-SD-Auto-Upload

## Description

OpenWrt-SD-Auto-Upload is an automation system for OpenWrt devices. It is designed to transfer the content of an SD card to a remote server without the need for a desktop computer.

Right now, Mapillary only accepts large video files (like 4K dashcam footage) when they are uploaded from a desktop. Mobile devices are not reliable for this task. This is because of restrictions from the operating system, unstable long-term transfers, and limited file handling capabilities. This creates problems for contributors using fully mobile setups.

This project provides a stable workaround.

It runs on an OpenWrt router and constantly checks a connected SD card. When the media is detected, the card is mounted and its contents are securely sent to a remote server using rsync over SSH. The server side keeps upload sessions separate. There, the mapillary_tools can process and submit the data to Mapillary.

The system is built for environments where nobody is present to use it. It can deal with USB SD readers that don't work well, inserting the media more than once, and losing network connection for a short time. Once it's set up, it runs on its own.

It is suitable for:

-	Workflows for capturing images using Dashcam and Mapillary  
-	Vehicles with LTE mapping rigs  
Field deployments that don't allow for desktop access  
-	Pipelines that automatically move data to another system  

Workflow:

1. Record a video using a dashcam.
2. Put the SD card into the OpenWrt router.
3. The router detects and transfers files automatically.
4. The remote server processes and uploads them.
5. You can reuse the SD card after transferring the files to it.

## Hardware

GL.iNet GL-XE300 (Puli)


## Preparations

Have a rsync server ready to receive the files.

Open the terminal and enter the following command:

`bash 
adduser sd-auto-upload1 --disabled-password
cd /home/sd-auto-upload1
ssh-keygen -f uploadkey_ed25519
chmod 600 uploadkey_ed25519`


## Packages

Type the following command:

`bash
opkg install openssh-client rsync`
