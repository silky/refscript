
/*@ foo :: (x:null, y:number) => number */
export function foo(x,y) {
    let r = <number> (x || y);      // no contextual type here -- hence using
                                    // the explicit cast
    return r;
}
