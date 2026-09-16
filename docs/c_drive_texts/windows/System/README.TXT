                     THE SYSTEM FOLDER
                     =================

The folder you were told never to open, whose contents you learned by heart
anyway, because every error message named one of them.

  *.DLL       A library shared between programs, and the reason a program
              that had worked for a year stopped working the day another
              program was installed. Installing anything meant putting one
              of these here, usually an older one, usually without asking.

  *.VXD       A driver that ran with the machine in its hands.

  *.CPL       A Control Panel page. Dropping one in this folder added a page
              to the Control Panel, which was either elegant or terrifying
              depending on where the file came from.

  REGEDIT     The registry editor, which was not in the Start menu, because
              you were not supposed to need it, which is how everybody knew
              you needed it.

WHAT IS HERE INSTEAD
--------------------

On this system there is no system folder, and nothing is shared by being in
the same place as something else. A module declares what it brings; the
runtime resolves it by version; two modules that need different versions of
the same thing get different versions of it, and neither one wins by having
installed itself last.

The Registry Editor is real here, and it is in the Start menu, under
Programs - it only asks for administrator rights. The registry it edits is
the running system's own: entries, not a hive, and no file you can corrupt
by opening it with the wrong program.

The files beside this one are names, kept as names. Nothing opens a .DLL,
which is exactly what a .DLL was for.
