
/*@ qualif CmpZ(v:int): v = 20 */

// This is a local variable
let glob = 20;


module A {


    function zog(){
      glob = 3;
    }

    zog();

    assert(glob === 20);

}
