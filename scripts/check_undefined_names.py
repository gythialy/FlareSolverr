#!/usr/bin/env python3
"""Fail when a module reads a global name that nothing at module level binds.

Such a name compiles fine and imports fine, but raises NameError the moment the
offending function runs -- exactly the class of bug that a stale conflict
resolution in a fork merge produces (e.g. dropping an import while keeping its
use). It is deliberately static: no project dependency is imported or executed.

Usage: python3 scripts/check_undefined_names.py <file.py> [more.py ...]
Exit code 0 when clean, 1 when undefined names were found.
"""

import builtins
import sys
import symtable

# Bound implicitly by the interpreter for any module.
IMPLICIT_NAMES = {
    "__annotations__",
    "__builtins__",
    "__cached__",
    "__doc__",
    "__file__",
    "__loader__",
    "__name__",
    "__package__",
    "__spec__",
}


def check_file(path):
    with open(path, encoding="utf-8") as handle:
        source = handle.read()

    try:
        module = symtable.symtable(source, path, "exec")
    except SyntaxError as exc:
        return ["%s:%s: syntax error: %s" % (path, exc.lineno, exc.msg)]

    module_names = {symbol.get_name() for symbol in module.get_symbols()}
    known = module_names | IMPLICIT_NAMES | set(dir(builtins))

    problems = []

    def walk(table, scope):
        for symbol in table.get_symbols():
            name = symbol.get_name()
            # is_global(): resolved against the module namespace, not a local.
            if symbol.is_global() and symbol.is_referenced() and name not in known:
                problems.append(
                    "%s: undefined name '%s' referenced in %s" % (path, name, scope)
                )
        for child in table.get_children():
            walk(child, "%s.%s" % (scope, child.get_name()))

    walk(module, "<module>")
    return problems


def main(argv):
    if not argv:
        print("usage: check_undefined_names.py <file.py> [...]", file=sys.stderr)
        return 2

    failures = []
    for path in argv:
        problems = check_file(path)
        if problems:
            failures.extend(problems)
        else:
            print("ok: %s" % path)

    for problem in failures:
        print(problem, file=sys.stderr)

    if failures:
        print(
            "\n%d undefined name reference(s) found; these raise NameError at runtime."
            % len(failures),
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
