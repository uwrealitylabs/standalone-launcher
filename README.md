# Standalone Launcher

Once Standalone gets to a stage where it supports running OpenXR applications, the final aspect of the project will be some sort of **user interface**. That is, how will users of our headset be able to select and launch OpenXR (or WebXR) applications without needing to link it with an external device?

The solution is this: A *custom launcher*. We develop our own OpenXR-based application that exposes a *launcher* environment to the user. In this launcher environment, the user can ideally browse installed OpenXR applications, browse the internet to download more, or launch WebXR experiences on the internet.

In addition, we would want to expose basic OS functionalities, e.g. a shell interface, file browsing, windows, etc.

## Implementation

To develop this application, there are a few options. Note that the Raspberry CM5’s processor uses ARM architecture, and thus any game engine or development platform we use must support compiling applications to Linux on ARM. Unfortunately, Unity does not compile to ARM Linux, but we do have other available options:

- Unreal Engine 5
- Godot
- Graphics API only (e.g. OpenGL/Vulkan)

With the presence of Godot, UE5 becomes overkill, so the choice is really just between Godot and no engine at all.

Although creating the launcher using something like OpenGL would be a fun technical challenge, the most practical option is undoubtedly Godot, as this will allow quick prototyping and iteration. Thus, assuming no compatibility issues down the road, **Godot** is what we will use to create this launcher.

## Plan

The current plan is as follows:

1. ~~Validate a Godot application on a Pi5 [DONE]~~
    1. Develop a simple Godot application, e.g. with a command line that can execute shell commands (this will be useful later for launching applications)
    2. Compile it and attempt to run it on a Raspberry Pi 5
2. ~~Test OpenXR functionality~~
    1. Install Monado on a Raspberry Pi 5
    2. Add some kind of XR feature to do the Godot application for testing purposes
    3. Emulate an OpenXR device with Monado https://redstrate.com/blog/2023/11/using-openxr-without-real-hardware/
    4. Test XR features, e.g. HMD tracking or controllers, on the Godot application
3. [CURRENT] Add basic OS functionality
    1. Add a 3D keyboard that can be interacted with in XR
    2. Add a bash shell interface
    3. Any other OS features that could be easily added in
5. Add functionality for querying launching applications
    1. Develop functionality within the launcher (in Godot) that allows a user to launch some arbitrary application.
    2. Make it so that users interacting with the launcher can query existing XR applications on the Pi5, and choose which one to launch. Potentially use a file system W shortcuts here.
    3. Test it
6. Make it so that the launcher runs on start-up as an OS wrapper
7. Add additional OS features, e.g. windows, browsing, desktop
8. Add embedded browser functionality for downloading applications
9. Make it so that downloaded applications can be automatically added to the UI and launched by the user
10. Add WebXR launching functionality from the embedded browser (potentially into a separate actual chromium process)
    1. Figure out how to get WebXR to work on linux with chromium
11. Test with our actual XR hardware
    1. Assuming Monado works fully with our hardware, test out our launcher
    2. Once this step is complete, then our MVP for Standalone is done! We have a standalone headset that a user can use to download & launch XR applications!
12. Testing & Polish
    1. Improve UI/UX

## Resources

[OpenXR with no hardware with Monado](https://redstrate.com/blog/2023/11/using-openxr-without-real-hardware/)

[Chromium embedded in Godot 4](https://github.com/Lecrapouille/gdcef)

[WebXR on Linux](https://github.com/mrxz/webxr-linux)
