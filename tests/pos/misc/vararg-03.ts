

/*@ buildName :: /\ (firstName: string) => string
                 /\ (firstName: string, lastName: string) => string
 */

function buildName(firstName: string, lastName?: string) {
    var zog = arguments.length;
    
    assert (zog > 0);

    if (arguments.length === 2)
        return firstName + " " + lastName;
    else
        return firstName;
}

var result1 = buildName("Bob");                  //works correctly now
var result3 = buildName("Bob", "Adams");         //ah, just right
