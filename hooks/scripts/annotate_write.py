"""annotate_write.py - the one atomic file write the annotate scripts share.

Every annotate writer that must never show a reader a half-written file goes
through write_atomic: the text goes into a temp file of this writer's own,
<name>.<random>.tmp in the target's own folder, and only then takes the
target's path. Two writers of one file never share a temp, and a reader sees
the old file or the new one, never part of either.

Each annotate program loads this file by its own directory: the shell scripts
export CRAFT_ANNOTATE_SCRIPTS_DIR from their own location (never inherited),
annotate-channel.py uses its __file__, and the external-page gate uses its
plugin root. The program puts that folder first on sys.path for the one import
and takes it off again. Nothing is installed and PYTHONPATH is never read.

It imports only os and tempfile. The external-page gate runs on every tool
call, so it imports this module inside the one function that writes, never at
the top of its program.
"""

import os
import tempfile


def write_atomic(path, text, mode=None, sync=False, exclusive=False):
    """Write text (a str, as UTF-8) to path through a temp file in its folder.

    mode       the file's permission bits, set before the text goes in; None
               keeps the temp's own 0600
    sync       flush and fsync the temp before it takes the path
    exclusive  create only: link the temp to path instead of replacing, so a
               file another writer already put there is never overwritten

    Returns True when the file is written; with exclusive, False when path
    already existed (that file is left as it was). On any error the temp is
    removed, path is left as it was, and the error is raised.
    """
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=os.path.basename(path) + ".", suffix=".tmp")
    try:
        if mode is not None:
            os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            if sync:
                handle.flush()
                os.fsync(handle.fileno())
        if not exclusive:
            os.replace(tmp, path)
            return True
        try:
            os.link(tmp, path)
            created = True
        except FileExistsError:
            created = False
        os.unlink(tmp)
        return created
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
