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

# Contribution Guidelines (Read me!)
To keep the project organized and improve efficiency, it's recommended that you familiarize yourself with the contribution guidelines below.

## Project Organization
For project organization, we generally follow the guidelines provided by the [Godot Docs](https://docs.godotengine.org/en/stable/tutorials/best_practices/project_organization.html). It's recommended that you give this a quick read.
Some important ones:
- Use **snake_case** for folder and file names.
- Use **PascalCase** for node names.
- In general, keep third-party resources in the top-level `addons/` folder, even if they aren't editor plugins.

## GDScript Style Guide
For programming in GDScript, we also follow the style guide provided by the [Godot Docs]. It's recommended that you also give this a quick read.
Some important guidelines:
- Follow [these naming conventions](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_styleguide.html#naming-conventions).
- Use **Tabs** for indentation (editor default)
- Surround function and class definitions with **two** blank lines.
- Keep lines of code **under 100 characters**
- [Format multiline statements for readability](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_styleguide.html#format-multiline-statements-for-readability)
