/*@ abs :: ({ x:number | true }) => {v:number | v > x} */ 
function abs(x){
  var res = 0;
  if (x > 0) {
    res = x;
  } else {
    res = -x;
  };
  assert(res >= 0);
  return res;
}
