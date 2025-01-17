/*@ abs :: ( f: ( top ) => number, x: number ) => number */
function abs(f, x) {
    var r = x;
    if (x < 0) {
      r = 0 - x;
    }
    r = f(r);
    assert(r >= 0);
    return r;
}


/*@ dubble :: (p:number) => number */
function dubble(p) {
    return p + p;
}


/*@ main :: (y:number) => {v:number | 0 < 1} */
function main(y) {
    var yy = abs(dubble, y);
    assert(yy >= 0);
    return yy;
}
