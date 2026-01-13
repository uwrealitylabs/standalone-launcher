# Standalone Launcher

Once Standalone gets to a stage where it supports running OpenXR applications, the final aspect of the project will be some sort of **user interface**. That is, how will users of our headset be able to select and launch OpenXR (or WebXR) applications without needing to link it with an external device?

The solution is this: A *custom launcher*. We develop our own OpenXR-based application that exposes a *launcher* environment to the user. In this launcher environment, the user can ideally browse installed OpenXR applications, browse the internet to download more, or launch WebXR experiences on the internet. In addition, we would want to expose basic OS functionalities, e.g. a shell interface, file browsing, windows, etc.

An example of an existing launcher environment —that we will likely end up copying a lot from —is Meta Horizon OS, illustrated below:
<img width="1024" height="576" alt="image" src="https://github.com/user-attachments/assets/2e5f28bf-83a0-473f-a164-9af4193a1501" />


More details can be found on this project's [Notion page](https://uwrl.notion.site/Custom-Launcher-23cbc072402f8060a9e2de823c607f72?source=copy_link)
