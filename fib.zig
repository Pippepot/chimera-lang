fn fib(n: i32) i32 {
    if (n == 1) return 1;
    if (n == 0) return 0;
    return fib(n - 1) + fib(n - 2);
}

pub fn main() !void {
    _ = fib(40);
}
