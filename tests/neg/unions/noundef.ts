
/*@ check_undefined :: forall T . (T + undefined) => T */
function check_undefined<T>(x:any) : T {
    if (typeof x === "undefined") 
        return crash();
    return <T>x;
}

/*@ bob :: (number) => number + undefined */
function bob(x:number):any {
    if (x > 0) return x;
    return undefined;
}

/*@ bar :: ({number | 0 < 1 }) => number */
function bar(x:number) : any {
    var z = bob(x);
    return z;
}
