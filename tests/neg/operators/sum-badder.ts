
/*@ sumLoop :: (number, number) => number */
function sumLoop(acc, i){
  var r = 0;
  if (0 < i){
    r = sumLoop(acc, i - 1);
  } else {
    r = acc;
  }
  return r;
}

/*@ main :: () => void */
function main(){
  var n = pos();
  var m = sumLoop(0, n);
  assert(m === n);
}
