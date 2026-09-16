                    CHICAGO DESKTOP - READ THIS FIRST
                    =================================

Welcome to Chicago.

This is the C: drive of a desktop that lives in a terminal. The windows are
drawn with pixels, the text with cells, and every program you see in the
Start menu is an entry in a registry the running system reads for itself.

The files in this folder are not read by anything. They are here because a
system folder full of INI files, logs and README.TXT is what a C: drive
looked like in 1995, and because a drive you can open and wander through
is more fun than a drive that is empty.

Nothing here can break the system. Nothing here can be executed. Read it,
open it in Notepad, close it again.


WHAT IS ACTUALLY RUNNING
------------------------

The shell        chicago.shell:shell - the desktop, the taskbar, the Start
                 menu and the logon screen.
The base         chicago.tui_desktop - the compositor, the windows, the
                 command channel. The shell is a look over it, not a copy.
The programs     Notepad, Calculator, Minesweeper, aICQ, Task Manager and
                 the rest are modules, each one its own repository, each
                 one resolved by a version tag.

The real settings are not in WIN.INI. They are in a database table and in
the registry, which is the point: an installed module brings its programs
with it and takes them away when it goes.


FILES IN THIS FOLDER
--------------------

WIN.INI          Settings, in the old shape. Read by nobody.
SYSTEM.INI       The same, for the parts that once booted the machine.
GENERAL.TXT      General notes about this system.
HARDWARE.TXT     What this system thinks your hardware is.
TIPS.TXT         Things worth knowing. The Welcome window shows them too.
CHICAGO.TXT      Why the desktop is called Chicago.
SUPPORT.TXT      Where to go when something is wrong.
BOOTLOG.TXT      What happened the last time the system started.

Media\           Sounds the terminal cannot play.
Help\            Help files, in the shape help files had.
System\          The parts a system keeps to itself.
Command\         The commands that once lived on the command line.
Temp\            Empty, as a Temp folder should be.
