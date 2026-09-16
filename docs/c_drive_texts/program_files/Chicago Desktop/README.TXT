                    CHICAGO DESKTOP
                    ===============

If this desktop had been a program you bought in a box, the box would have
been wider than it was deep, the manual would have been spiral-bound, and
this file would have been on the last floppy.

It is not a program. It is an application composed of modules, and this is
what it is made of.


THE PARTS
---------

  runtime         A fork of the wippy runtime. Two things live in the fork
                  and not upstream: a gfx module that draws rasters into a
                  terminal, and an SSH host that gives every connection a
                  desktop of its own. A release runtime cannot boot this
                  application - it does not know those words.

  tui-desktop     The base: the compositor, the window host, the pseudo
                  terminals, the command channel, the workshop. It has no
                  look of its own.

  shell           The look: the theme, the taskbar, the Start menu built
                  from the registry, the logon screen, the desktop layout,
                  the folder windows, Notepad, the picture viewer, and the
                  SDK every window on this desktop is written against.

  app             The application: the logon, the SSH host, the system
                  windows, and the list of which modules are installed.

  the programs    One repository each: Minesweeper, aICQ, the calculator,
                  Date/Time, Task Manager, the Registry Editor, Add/Remove
                  Programs, Network, Run, AntiBug, Weather, Users,
                  Services, Scheduled Tasks, Events, Connections, Welcome,
                  the floppy drive.


HOW IT IS PUT TOGETHER
----------------------

Every module is resolved from its repository by a version tag and written
into a lock file with the commit it came from and a hash of its contents. A
moved tag changes nothing until someone updates on purpose. A fresh checkout
needs the network once; after that it boots offline.

Add/Remove Programs edits the folder of declarations, which you can open on
C: yourself, and which is the only list of what is installed. There is no
second list to keep in step.


A NOTE ON THE LOOK
------------------

The chrome is drawn in pixels and the text in cells, and the choice was made
by measurement rather than taste: a full screen of pixels costs about 47
milliseconds, the edges of one window under a millisecond, and text as text
stays text you can select.

The icons are an interim set, being replaced by original pixel art. The
fonts are Liberation, under the SIL Open Font License. Everything else was
written for this.
