
/*@ incr :: (x:number) => {number|v = x + 1} */
function incr(x:number):number{
    return ++x;
}

/*@ foo :: (x:number) => {number|v = 3*x + 4} */
function foo(x:number):number{
    return x += incr(x++) + incr(x++);
}

