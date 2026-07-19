Sales Quotation: 
1. Sales Person : dropdown is not enterable by keyboard UP/DOWN key. It should be sale as Location dropdown. 
2. Quotation No and Quotation Date, should be in top row, before Quotation Type (Existing Customer, Prospect)	
3. Product dropdown is not keyboard enabled, UP/Down key not working
4. There should be separate columns for Unit- this issue persist across many screens, Please fix at all pages. 
5. All dropdown across entire app should be keyboard enable (UP/DOWN) key should allow user to select values from list
6. Can we have a keyboard shortcut to add new Product line? like pressing ALT+A, we will discuss about shortcuts capability
7. As we have now enabled Product Price screen, so product price should be fetched from Price master
8. Email fields (if entered by user) should be validate and always be a valid email.
9. In Quotation Print, Prepared by and Authorized by names are not being printed.
10. when Printing on mobile- Pdf is appearing on same screen and there is no way to go back to main screen, this issue persist on all print button on mobile. we have to think about a generic solution. 
11. Quotation List, Number format is not yet applied. 
12. what is "Send to customer" button do? what is the functionality.
13. When I converted quotation to sales order, qty became 0 in sales order and sales order get saved with zero qty and zero value. 
14. When I canceled a a sales order, in print it is showing DRAFT
14. When I converted a Prospect into customer, in RIM_accounts table it inserted accounting_std as OHADA while out comply setting says "INDIAN" 
15. Conveted Prospect not appearing on other screens, It only appeared once I log out and login again.

Sales Order Testing. 
1. order List Number format
2. Order List : "Source SQ" should be rename to "QUOTATION"
3. In sales order screen customer are not selectable by keyboard. UP/DOWN
4.  Customer dropdown showing all record where account nature is "CUSTOMER" while it should only show customer not the group names (or Group Node)
5. Order No and Order date should be on top row, in middle row is weird, user should select order date first then other things. 
6. Sales person also not selectable by keyboard.
7. When I select currency, it should fetch the exchange rate. 
8. Product lines have same issue as quotation, Uni should be show separately, currently it is mixed with qty. 
9. Product price should be fetch from price master , based on currency.. 
10. I am able to save order without Price , which is wrong. 
11. in other changers I am able to enter negative amount, Please check this in all screens wherever we have implemented other charges. 
12. Order amount can not be negative 
13. Discount can not more than 100% and most importantly user defined limit. every user has his discount limit.	
14. While printing, "canceled" order should be printed as "canceled" not as "draft"
15. Number format in order and order listing
16. While converting Sales quotation into sales order, other charges are not being carry forwarded. 
17. future date and lock period check should be there on sales order, sales quotation and sales invoice screen
18. Order date cannot be less than sales quotation date.
19. similarly, Invoice date can not be less than sales order date or sales quotation date , if being made against order or quotation.