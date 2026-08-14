#!/usr/bin/env python

def fib(n):
    if n <= 2:
        return 1
    return fib(n - 1) + fib(n - 2)

def fib_iter(n):
    def fib_iter_inner(a, b, n):
        if(n == 0):
            return a
        return fib_iter_inner(b, a+b, n-1)

    return fib_iter_inner(0, 1, n)

print(fib(35))
# print(fib_iter(70))
