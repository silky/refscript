
/*@ init :: (number) => {v: number | v > 0} */
function init(n:number): number {
  let i: number;
  if (n > 0) {
    i = 1;
  } else {
    i = 2;
  }
  return i;
}