/*@ qualif NonNeg(v:number): v >= 0 */




/*@ abs :: ({ x:number | 0 < 1}) => number */ 
function abs(x){
  var res = 0;
  if (x > 0) {
    res = x;
  } else {
    res = -x;
  };

  assert(res >= 10);
  return res;
}
