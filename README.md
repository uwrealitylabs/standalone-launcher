# Standalone Launcher

Once Standalone gets to a stage where it supports running OpenXR applications, the final aspect of the project will be some sort of **user interface**. That is, how will users of our headset be able to select and launch OpenXR (or WebXR) applications without needing to link it with an external device?

The solution is this: A *custom launcher*. We develop our own OpenXR-based application that exposes a *launcher* environment to the user. In this launcher environment, the user can ideally browse installed OpenXR applications, browse the internet to download more, or launch WebXR experiences on the internet. In addition, we would want to expose basic OS functionalities, e.g. a shell interface, file browsing, windows, etc.

An example of an existing launcher environment —that we will likely end up copying a lot from —is Meta Horizon OS, illustrated below:
<img width="1024" height="576" alt="image" src="https://github.com/user-attachments/assets/2e5f28bf-83a0-473f-a164-9af4193a1501" />
_Meta Horizon OS ([Source](https://www.uploadvr.com/meta-teases-the-future-of-horizon-os/))_

More details can be found on this project's [Notion page](https://uwrl.notion.site/Custom-Launcher-23cbc072402f8060a9e2de823c607f72?source=copy_link)

# Contribution Setup
This is a **Godot** project, so setting up will involve first downloading Godot, and then opening this project in Godot.

## Godot Installation
<img width="480" height="270" alt="image" src="https://github.com/user-attachments/assets/115d865a-b0f8-49ac-804c-98c0f366faed" />

This project uses Godot _v4.5_, which can be downloaded [here](https://godotengine.org/download/archive/#:~:text=4.5%2Dstable,15%20September%202025).
After the .zip file is downloaded, you can follow the rest [this video](https://youtu.be/WsRgIVg0nGM?t=46) for the remaining setup. This will likely take you less than two minutes.

## Cloning (Downloading) the Project
Now that you Godot is installed, you'll want to download the Standalone Launcher projeect onto your computer. To do this, you're going to clone this github repository. This will download the current state of the project onto your computer, in addition to allowing you to make local changes, and then later push those changes back into the project. 

To clone the repository, follow [this tutorial](https://docs.github.com/en/repositories/creating-and-managing-repositories/cloning-a-repository). Ensure to remember where (i.e. the path to the folder) you clone the repository to within your file system.

## Importing the Project
You're now ready to open the project! First, open Godot if it's not already open, and you should see a screen similar to what is shown below:

<img width="1150" height="835" alt="image" src="https://github.com/user-attachments/assets/c2b76c2c-bb4d-42b3-8907-b2212d27604a" />

From here, click on "Import", and then navigate to and select the folder where you cloned the Standalone Launcher repository. In the example below, the repo was cloned to `C:/Users/ntabl/dev/GodotProjects/standalone-launcher`

1)
<img width="125" height="56" alt="image" src="https://github.com/user-attachments/assets/532af4f7-cbc5-4377-818f-d75ceec3817f" />

2)
<img width="519" height="371" alt="image" src="https://github.com/user-attachments/assets/f39cacc6-079c-4c2a-86ad-8cf3ffcb6d62" />

3)
<img width="246" height="141" alt="image" src="https://github.com/user-attachments/assets/046d9d12-b72d-4740-8845-af58fed7c1ea" />

If successful, the project should open once you click "Import" on the final screen, and you should now be able to see an editor window open in the project. Something like this:

<img width="2546" height="1514" alt="image" src="https://github.com/user-attachments/assets/253cc84a-1b6f-47c2-9d04-aac6ad93ea53" />

With that, you're all set to contribute. Get to building!

## Build Instructions

### Setup the Default Scene **(THIS IS WHAT SCENE THE EXECUTABLE WILL START)**

Navigate to the project settings tab:

<img width="355" height="287" alt="image" src="https://github.com/user-attachments/assets/afa83136-d5b1-49c4-a30c-59cf1d588b07" >

In the search bar type "Main Scene" and you should see this setting:

<img width="597" height="368" alt="image" src="https://github.com/user-attachments/assets/7d3fd1c6-df99-4fec-bfe6-4cf2864ba734" />

Click here to change the file path:

<img width="489" height="20" alt="image" src="https://github.com/user-attachments/assets/096438c5-8859-4003-bb92-db85f9790883" />

From here, you can browse the project file structure and select the scene you want and then click open:

<img width="523" height="371" alt="image" src="https://github.com/user-attachments/assets/9c52826e-6380-4a94-923d-c25020f61fe3" />

Now you have set your default scene and a ready to start the export process!

## Exporting build in Godot

Open the project you want to export into a executable and click on the Export.. button in the project tab.

<img width="941" height="584" alt="Screenshot 2026-02-28 152731" src="https://github.com/user-attachments/assets/92b73489-ccc5-4414-98aa-7fa21daadc9a" />

If this your first time opening the Export page you have to click on Manage Export Templates.

<img width="1124" height="769" alt="Screenshot 2026-02-28 153724" src="https://github.com/user-attachments/assets/0b4c297a-4c52-440a-b055-0ef1bfa922f3" />

From here, click on Download and Install and wait for it to finish.

<img width="902" height="422" alt="Screenshot 2026-02-28 154223" src="https://github.com/user-attachments/assets/673f8ba6-7fd9-4544-a3b0-b79973022c34" />

From here, make sure your Architecture is set to arm64 (it should be by default) and then click Export Project...

<img width="1213" height="835" alt="Screenshot 2026-02-28 154506" src="https://github.com/user-attachments/assets/886c072e-2f05-4593-9524-30dade6df4bb" />

Now configure the path you want the executable saved to and decide the name (By default the name is the same as the Project Name) then just click save.

<img width="524" height="368" alt="image" src="https://github.com/user-attachments/assets/cc7a8150-a837-43be-bec1-a6bb575d526e" />

Once your done you should see 3 files in your chosen folder like this:

<img width="525" height="71" alt="image" src="https://github.com/user-attachments/assets/63f34254-d758-4d04-b03e-bf2f1f004119" />

## Transfer the executable to the PI

Now launch your command promt of choice of navigate to the path your files are in like this:

<img width="860" height="208" alt="image" src="https://github.com/user-attachments/assets/9e6b931b-220a-4382-aaa1-def19eef6f35" />

From here make sure you are connected to the same WIFI as your Raspberry Pi device and find the name. The easiest way to do this is to just open command promt on the PI and locate it like this:

<img width="415" height="293" alt="image" src="https://github.com/user-attachments/assets/011afda5-e682-470c-9567-f1eb4649a147" />

Now just enter this command replacing the file name and raspberry pi name with the your's:

<img width="344" height="58" alt="image" src="https://github.com/user-attachments/assets/473b6a0b-d557-426b-9171-5db0f4274e4e" />

Now enter the password of pi and if successful you should see the installation progress:

<img width="860" height="80" alt="image" src="https://github.com/user-attachments/assets/0ce71bdc-fa06-49e5-8784-96a946ab0da5" />

Once completed you should see the files in the root of the user folder:

<img width="1056" height="441" alt="image" src="https://github.com/user-attachments/assets/44c252ed-544d-42bf-a18e-c804c389e0a3" />

## Run the executable on the PI

From here, alter the permissions of the the file using the following command:

<img width="413" height="142" alt="image" src="https://github.com/user-attachments/assets/12100284-507c-4575-a8a3-101f50eae401" />

Now you can launch the application in the console:

<img width="415" height="293" alt="image" src="https://github.com/user-attachments/assets/00f9785a-7916-4587-b563-942a54005f5a" />

if successful you should see this (or something similar, depending on what the default scene contains):

<img width="1204" height="680" alt="image" src="https://github.com/user-attachments/assets/2a53250f-5913-46f8-a650-8ade6499ffa0" />

Congrats, now you can use your application!
