#!/usr/bin/env python3
"""Official final-evaluation CLI. No fixed delivery directory dependency."""
import sys
sys.dont_write_bytecode = True
from accuracy_completion import main

if __name__ == '__main__':
    sys.exit(main())
