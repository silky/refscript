/*@ qualif CondLock1(v:number,x:number): v = (if (0 <= x) then 1 else 0)  */    
/*@ qualif CondLock2(v:number,x:number): v = (if (0 < x) then 1 else 0)  */    

/*@ create :: () => number */
function create(){
  //ensures($result === 0);
  return 0;
}

/*@ acquire :: (number) => number */
function acquire(l){
  //requires(l === 0);
  //ensures($result === 1);
  return 1;
}

/*@ release :: (number) => number */
function release(l){
  //requires(l === 1);
  //ensures($result === 0);
  return 0;
}



/*@ main :: () => { void | true } */
function main(){
  var x = random();
  var l = create();
  if (0 <= x){ l = acquire(l); }
  if (0 < x){ l = release(l); }
  assert(l === 0);
}

