
/*@ foo :: (x:null, y:number) => { number | true } */
function foo(x,y) {

    var r = <number> (x || y);      // no contextual type here -- hence using
                                    // the explicit cast

    return r; 
}
