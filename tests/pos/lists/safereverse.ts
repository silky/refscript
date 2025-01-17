/*@ qualif Len(v:a)               : 0 <= (len xs)                 */
/*@ qualif EqLen(v:a, xs:b)       : (len v) = (len xs)            */
/*@ qualif SumLen(v:a, xs:b, ys:c): (len v) = (len xs) + (len ys) */

/*@ reverse :: forall A. (xs: #List [A]?) => {v: #List [A]? | (len v) = (len xs)} */
function reverse(xs){

  /*@ go :: (#List[A]?, #List[A]?) => #List[A]? */ 
  function go(acc, ys){
    if (empty(ys)){
      return acc;
    }
    
    var y    = safehead(ys);
    var ys_  = safetail(ys);
    var acc_ = cons(y, acc);
    
    return go(acc_, ys_);
  }
  var b = nil();
  return go(b, xs);
}

