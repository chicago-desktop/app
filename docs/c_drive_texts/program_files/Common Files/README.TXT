                       COMMON FILES
                       ============

The folder every installer wrote into and no uninstaller ever emptied.

The idea was good: things two programs both needed would be kept once,
here, instead of twice, in two program folders. What happened instead was
that every installer put its own copy of the shared thing here, each a
slightly different version, each overwriting the last, and the program that
had been installed most recently was the one that worked.

Uninstalling gave you a dialog: "This file may be in use by other programs.
Are you sure you want to remove it?" - and nobody, in the entire decade,
answered Yes with any confidence.

By 1999 this folder held hundreds of megabytes of things nothing needed, and
removing any of them was a bet.


WHAT THIS SYSTEM DOES INSTEAD
-----------------------------

Nothing is shared by being in the same place as something else.

A module names what it depends on and the version range it accepts. The
runtime resolves that, writes down the exact commit and a hash of the
contents, and two modules that need two different versions get two different
versions. Removing a module removes what it brought with it, because what it
brought was never anywhere but inside it.

There is no dialog asking whether a file may be in use by other programs,
and there never has to be.
