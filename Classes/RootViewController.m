//
//  RootViewController.m
//  iRedmine
//
//  Created by Thomas Stägemann on 31.03.09.
//  Copyright Thomas Stägemann 2009. All rights reserved.
//

#import "RootViewController.h"
#import "iRedmineAppDelegate.h"

@implementation RootViewController

@synthesize badgeCell;
@synthesize addViewController;
@synthesize projectTableController;
@synthesize projectViewController;
@synthesize accountTable;
@synthesize networkQueue;

- (void)viewDidLoad 
{
    [super viewDidLoad];
	
	//[self setTitle:@"iRedmine"];
    // Uncomment the following line to display an Edit button in the navigation bar for this view controller.
    //self.navigationItem.rightBarButtonItem = self.editButtonItem;
	networkQueue = [[ASINetworkQueue queue] retain];	

	NSUserDefaults * defaults = [NSUserDefaults standardUserDefaults];
	
	// First Launch
	BOOL launchedBefore = [defaults boolForKey:@"launchedBefore"];
	if(!launchedBefore) 
	{
		NSArray * demoURLStrings = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"DemoURLs"];
		NSMutableDictionary * accounts = [NSMutableDictionary dictionary];

		for (NSString * demoURLString in demoURLStrings) 
		{
			NSDictionary * demoAccount = [NSDictionary dictionaryWithObjectsAndKeys:demoURLString, @"url",@"", @"username", @"", @"password", nil];
			[accounts setObject:demoAccount forKey:demoURLString];
		}
		
		[defaults setObject:accounts forKey:@"accounts"];	
		[defaults setBool:YES forKey:@"launchedBefore"];
		[defaults synchronize];		
		[self refreshProjects:self];
	}	
}

- (IBAction)openPreferences:(id)sender
{
	if(self.addViewController == nil)
		self.addViewController = [AddViewController sharedAddViewController];
	
	[self.navigationController pushViewController:self.addViewController animated:YES];	
}

- (IBAction)refreshProjects:(id)sender
{	
	NSUserDefaults * defaults = [NSUserDefaults standardUserDefaults];
	NSSortDescriptor * sortDescriptor = [[NSSortDescriptor alloc] initWithKey:@"url" ascending:YES];
	NSArray * accounts = [[[defaults dictionaryForKey:@"accounts"] allValues] sortedArrayUsingDescriptors:[NSArray arrayWithObject:sortDescriptor]];
	
	[networkQueue cancelAllOperations];
	[networkQueue setRequestDidStartSelector:@selector(fetchBegins:)];
	[networkQueue setRequestDidFinishSelector:@selector(fetchComplete:)];
	[networkQueue setRequestDidFailSelector:@selector(fetchFailed:)];
	[networkQueue setQueueDidFinishSelector:@selector(queueDidFinish:)];
	[networkQueue setShowAccurateProgress:YES];
	[networkQueue setShouldCancelAllRequestsOnFailure:NO];
	[networkQueue setDelegate:self];

	for(NSDictionary * account in accounts)	
	{								
		id projectsRequest = [[self requestWithAccount:account URLPath:@"/projects?format=atom"] retain];
		[projectsRequest setUserInfo:[NSDictionary dictionaryWithObjectsAndKeys:@"projects",@"feed",account,@"account",nil]];
		[networkQueue addOperation:projectsRequest];		
	}
	
	[networkQueue go];
	[accountTable reloadData];
}

- (ASIFormDataRequest *)requestWithAccount:(NSDictionary *)account URLPath:(NSString *)path
{
	NSString * password  = [account valueForKey:@"password"];
	NSString * username  = [account valueForKey:@"username"];
	NSString * urlString = [account valueForKey:@"url"];
	
	NSURL * loginURL = [NSURL URLWithString:[urlString stringByAppendingString:@"/login"]];
	NSURL * feedURL  = [NSURL URLWithString:[urlString stringByAppendingString:path]];
	NSLog(@"feed URL: %@",feedURL);
	
	ASIFormDataRequest * request;
	if(([password length] > 0) && ([username length] > 0))
	{
		request = [ASIFormDataRequest requestWithURL:loginURL];
		[request setPostValue:username forKey:@"username"];
		[request setPostValue:password forKey:@"password"];
		[request setPostValue:[feedURL absoluteString] forKey:@"back_url"];
	} 
	else 
	{
		request = [ASIFormDataRequest requestWithURL:feedURL];
	}
	
	[request setTimeOutSeconds:300];
	[request setUseKeychainPersistance:YES];
	[request setShouldPresentAuthenticationDialog:YES];
	if ([[[request url] scheme] isEqualToString:@"https"]) 
		[request setValidatesSecureCertificate:NO];
	return request;
}

- (void)fetchBegins:(id)request
{
}

- (void)fetchFailed:(id)request
{
	if ([[request error] code] != ASIRequestCancelledErrorType) 
	{
		UIAlertView * errorAlert = [[UIAlertView alloc] initWithTitle:[[request url] host] message:[[request error] localizedDescription] delegate:self cancelButtonTitle:@"OK" otherButtonTitles:nil];
		[errorAlert show];
	}
}

- (void)fetchComplete:(id)request
{
	NSString * host = [[request userInfo] valueForKeyPath:@"account.url"];
	//NSLog(@"Fetch from %@ completed: %@",host,[request responseString]);
	
	// Load and parse the xml response
	TBXML * xml = [[TBXML alloc] initWithXMLString:[request responseString]];

	if ([[request responseString] hasPrefix:@"<?xml"] && [xml rootXMLElement]) 
	{
		NSUserDefaults * defaults = [NSUserDefaults standardUserDefaults];
		NSMutableDictionary * accounts = [[defaults dictionaryForKey:@"accounts"] mutableCopy];
		NSMutableDictionary * account = [[accounts valueForKey:host] mutableCopy];

		NSString * feedInfo = [[request userInfo] valueForKey:@"feed"];
		if ([feedInfo isEqualToString:@"projects"]) 
		{
			NSArray * projects = [self arrayOfDictionariesWithXML:xml forKeyPaths:[NSArray arrayWithObjects:@"title",@"content",@"id",@"updated",nil]];
			[account setValue:projects forKey:@"projects"];

			// My Page
			NSString * password = [account valueForKey:@"password"];
			NSString * username = [account valueForKey:@"username"];
			if([password length] > 0 && [username length] > 0)
			{
				ASIFormDataRequest * assignedRequest = [[self requestWithAccount:account URLPath:@"/issues?format=atom&assigned_to_id=me"] retain];
				[assignedRequest setUserInfo:[NSDictionary dictionaryWithObjectsAndKeys:@"assigned",@"feed",account,@"account",nil]];
				[networkQueue addOperation:assignedRequest];
				
				ASIFormDataRequest * reportedRequest = [[self requestWithAccount:account URLPath:@"/issues?format=atom&author_id=me"] retain];
				[reportedRequest setUserInfo:[NSDictionary dictionaryWithObjectsAndKeys:@"reported",@"feed",account,@"account",nil]];
				[networkQueue addOperation:reportedRequest];
			}
			
			// Issues & activities for each project
			int i = 0;
			for (id project in projects) 
			{
				int projectId = [[[project valueForKey:@"id"] lastPathComponent] intValue];
				
				NSString * issuesPath = [NSString stringWithFormat:@"/projects/%d/issues?format=atom",projectId];
				ASIFormDataRequest * issuesRequest = [[self requestWithAccount:account URLPath:issuesPath] retain];
				[issuesRequest setUserInfo:[NSDictionary dictionaryWithObjectsAndKeys:@"issues",@"feed",account,@"account",[NSNumber numberWithInt:i],@"project",nil]];
				[networkQueue addOperation:issuesRequest];
				
				NSString * activityPath = [NSString stringWithFormat:@"/projects/activity/%d?format=atom",projectId];
				ASIFormDataRequest * activityRequest = [[self requestWithAccount:account URLPath:activityPath] retain];
				[activityRequest setUserInfo:[NSDictionary dictionaryWithObjectsAndKeys:@"activity",@"feed",account,@"account",[NSNumber numberWithInt:i++],@"project",nil]];
				[networkQueue addOperation:activityRequest];
			}
		} 
		else if ([feedInfo isEqualToString:@"assigned"]) 
		{
			NSArray * assignedIssues = [self arrayOfDictionariesWithXML:xml forKeyPaths:[NSArray arrayWithObjects:@"title",@"content",@"id",@"updated",@"author.name",nil]];
			[account setValue:assignedIssues forKey:@"assigned"];
		} 
		else if ([feedInfo isEqualToString:@"reported"]) 
		{
			NSArray * reportedIssues = [self arrayOfDictionariesWithXML:xml forKeyPaths:[NSArray arrayWithObjects:@"title",@"content",@"id",@"updated",@"author.name",nil]];
			[account setValue:reportedIssues forKey:@"reported"];
		} 
		else if ([feedInfo isEqualToString:@"issues"]) 
		{
			NSArray * projectIssues = [self arrayOfDictionariesWithXML:xml forKeyPaths:[NSArray arrayWithObjects:@"title",@"content",@"id",@"updated",@"author.name",nil]];
			NSMutableArray * projects = [[account valueForKey:@"projects"] mutableCopy];
			NSMutableDictionary * project = [[projects objectAtIndex:[[[request userInfo] valueForKey:@"project"] intValue]] mutableCopy];
			[project setValue:projectIssues forKey:@"issues"];
			[projects replaceObjectAtIndex:[[[request userInfo] valueForKey:@"project"] intValue] withObject:project];
			[account setValue:projects forKey:@"projects"];
			//NSLog(@"issues: %@",projectIssues);
		} 
		else if ([feedInfo isEqualToString:@"activity"]) 
		{
			NSArray * projectActivity = [self arrayOfDictionariesWithXML:xml forKeyPaths:[NSArray arrayWithObjects:@"title",@"content",@"id",@"updated",@"author.name",nil]];
			NSMutableArray * projects = [[account valueForKey:@"projects"] mutableCopy];
			NSMutableDictionary * project = [[projects objectAtIndex:[[[request userInfo] valueForKey:@"project"] intValue]] mutableCopy];
			[project setValue:projectActivity forKey:@"activity"];
			[projects replaceObjectAtIndex:[[[request userInfo] valueForKey:@"project"] intValue] withObject:project];
			[account setValue:projects forKey:@"projects"];
			//NSLog(@"activity: %@",projectActivity);
		}
		
		[accounts setValue:account forKey:host];
		[defaults setObject:accounts forKey:@"accounts"];
		[defaults synchronize];
		[accountTable reloadData];		
	} 
	else 
	{
		//NSLog(@"Fetch from %@ with invalid xml: %@",host,[request responseString]);
		NSString * errorString = NSLocalizedString(@"Invalid XML responded\n\nPossible reasons:\n1. password or username incorrect\n2. Too many requests\n3. Mobile skin corrupted",@"Invalid XML responded\n\nPossible reasons:\n1. password or username incorrect\n2. Too many requests\n3. Mobile skin corrupted");
		NSDictionary * errorUserInfo = [NSDictionary dictionaryWithObjectsAndKeys:errorString,NSLocalizedDescriptionKey,nil];
		NSError * error = [NSError errorWithDomain:@"InvalidXMLResponse" code:ASIUnhandledExceptionError userInfo:errorUserInfo];
		[request setError:error];
		[self fetchFailed:request];
	}

}

- (void)queueDidFinish:(ASINetworkQueue *)queue
{
	[accountTable reloadData];		
}

- (NSArray *)arrayOfDictionariesWithXML:(TBXML *)xml forKeyPaths:(NSArray *)keyPaths
{
	// Obtain root element
	TBXMLElement * root = [xml rootXMLElement];
	
	// instantiate an array to hold child dictionaries
	NSMutableArray * array = [NSMutableArray array];
	
	// search for the first child element within the root element's children
	TBXMLElement * entry = [xml childElementNamed:@"entry" parentElement:root];
	
	// if an child element was found
	while (entry != nil) 
	{	
		NSMutableDictionary * dict = [NSMutableDictionary dictionary];
		
		for (NSString * keyPath in keyPaths) 
		{
			NSArray * components = [keyPath componentsSeparatedByString:@"."];	
			TBXMLElement * parent = entry;
			TBXMLElement * element;
			for (NSString * component in components) 
			{
				element = [xml childElementNamed:component parentElement:parent];
				parent = element;
			}
			[dict setValue:[[xml textForElement:element] stringByUnescapingHTML] forKey:keyPath];
		}		
		
		[array addObject:dict];
		
		// find the next sibling element named "entry"
		entry = [xml nextSiblingNamed:@"entry" searchFromElement:entry];
	}
	
	return array;
}

- (void)viewDidAppear:(BOOL)animated 
{
    [super viewDidAppear:animated];
	[accountTable reloadData];
}

/*
 - (void)viewWillAppear:(BOOL)animated {
 [super viewWillAppear:animated];
 }
 */
/*
- (void)viewWillDisappear:(BOOL)animated {
	[super viewWillDisappear:animated];
}
*/
/*
- (void)viewDidDisappear:(BOOL)animated {
	[super viewDidDisappear:animated];
}
*/

// Override to allow orientations other than the default portrait orientation.
- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation 
{
    // Return YES for supporting all orientations
	return YES;
}

- (void)didReceiveMemoryWarning 
{
    [super didReceiveMemoryWarning]; // Releases the view if it doesn't have a superview
    // Release anything that's not essential, such as cached data
}

#pragma mark Table view methods

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView 
{
    return 1;
}


// Customize the number of rows in the table view.
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section 
{
	NSUserDefaults * defaults = [NSUserDefaults standardUserDefaults];
    return [[defaults dictionaryForKey:@"accounts"] count];
}


// Customize the appearance of table view cells.
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath 
{    
    static NSString *CellIdentifier = @"AccountCell";
 	NSUserDefaults * defaults = [NSUserDefaults standardUserDefaults];
	NSDictionary * accountDict = [[[defaults dictionaryForKey:@"accounts"] allValues] objectAtIndex:indexPath.row];

    badgeCell = (BadgeCell *)[tableView dequeueReusableCellWithIdentifier:CellIdentifier];
	if(badgeCell == nil)
        [[NSBundle mainBundle] loadNibNamed:@"BadgeCell" owner:self options:nil];
		
	NSString * username = [accountDict valueForKey:@"username"];
	if([username length] == 0) username = NSLocalizedString(@"Anonymous",@"Anonymous");
		
	NSString * subtitle = [NSString stringWithFormat:NSLocalizedString(@"Username: %@",@"Username: %@"),username];
	NSString * urlString = [accountDict valueForKey:@"url"];
	NSURL * url = [NSURL URLWithString:urlString];
	
	[badgeCell setCellDataWithTitle:[url host] subTitle:subtitle];
	[badgeCell setBadge:[[accountDict valueForKey:@"projects"] count]];
	if([[accountDict valueForKey:@"projects"] count] == 0)
		[badgeCell setAccessoryType:UITableViewCellAccessoryNone];
	else 
		[badgeCell setAccessoryType:UITableViewCellAccessoryDisclosureIndicator];
	
	if ([networkQueue isNetworkActive]) 
	{
		for (id request in [networkQueue operations]) 
		{
			if([[[request url] host] isEqualToString:[url host]])
			{
				UIActivityIndicatorView * activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
				[activityIndicator startAnimating];
				[badgeCell setAccessoryView:activityIndicator];
			}			
		}
	}  
	return badgeCell;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath
{
	return UITableViewCellEditingStyleDelete;
}

// Override to support editing the table view.
- (void)tableView:(UITableView*)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath 
{
    if (editingStyle == UITableViewCellEditingStyleDelete)
	{
		NSUserDefaults * defaults = [NSUserDefaults standardUserDefaults];
		NSMutableDictionary * accounts = [[defaults valueForKey:@"accounts"] mutableCopy];
		NSString * key = [[accounts allKeys] objectAtIndex:indexPath.row];
		[accounts removeObjectForKey:key];
		[defaults setValue:accounts forKey:@"accounts"];
		[defaults synchronize];
		// Delete the row from the data source
		[tableView deleteRowsAtIndexPaths:[NSArray arrayWithObject:indexPath] withRowAnimation:YES];
    }
}

// Override to support conditional editing of the table view.
- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath 
{
	NSUserDefaults * defaults = [NSUserDefaults standardUserDefaults];
	NSDictionary * accountDict = [[[defaults dictionaryForKey:@"accounts"] allValues] objectAtIndex:indexPath.row];
	
	if ([networkQueue isNetworkActive]) 
	{
		NSURL * url = [NSURL URLWithString:[accountDict valueForKey:@"url"]];
		for (id request in [networkQueue operations]) 
		{
			if([[[request url] host] isEqualToString:[url host]]) return NO;
		}
	}  
	
	// Return NO if you do not want the specified item to be editable.
	return YES;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath 
{
	NSUserDefaults * defaults = [NSUserDefaults standardUserDefaults];
	NSDictionary * accountDict = [[[defaults dictionaryForKey:@"accounts"] allValues] objectAtIndex:indexPath.row];
	
	if ([networkQueue isNetworkActive]) 
	{
		NSURL * url = [NSURL URLWithString:[accountDict valueForKey:@"url"]];
		for (id request in [networkQueue operations]) 
		{
			if([[[request url] host] isEqualToString:[url host]]) return;
		}
	}  

	NSString * password = [accountDict valueForKey:@"password"];
	NSString * username = [accountDict valueForKey:@"username"];
	NSArray  * projects = [accountDict valueForKey:@"projects"];

	if ([projects count] == 1 && ([username length] == 0 || [password length] == 0)) 
	{
		if(self.projectViewController == nil)
			self.projectViewController = [[ProjectViewController alloc] initWithNibName:@"ProjectView" bundle:nil];
		
		self.projectViewController.project = [projects objectAtIndex:0];		
		[self.navigationController pushViewController:self.projectViewController animated:YES];
	}
	else if ([projects count] > 0)
	{
		if(self.projectTableController == nil)
			self.projectTableController = [[ProjectTableController alloc] initWithNibName:@"ProjectTableView" bundle:nil];
		
		self.projectTableController.accountDict = accountDict;	
		[self.navigationController pushViewController:self.projectTableController animated:YES];
	}

}

/*
// Override to support rearranging the table view.
- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)fromIndexPath toIndexPath:(NSIndexPath *)toIndexPath {
}
*/


/*
// Override to support conditional rearranging of the table view.
- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    // Return NO if you do not want the item to be re-orderable.
    return YES;
}
*/


- (void)dealloc {
	[badgeCell release];
	[addViewController release];
	[projectTableController release];
	[projectViewController release];
	[accountTable release];
	[networkQueue release];
    [super dealloc];
}


@end

