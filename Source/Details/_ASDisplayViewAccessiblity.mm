//
//  _ASDisplayViewAccessiblity.mm
//  Texture
//
//  Copyright (c) Facebook, Inc. and its affiliates.  All rights reserved.
//  Changes after 4/13/2017 are: Copyright (c) Pinterest, Inc.  All rights reserved.
//  Licensed under Apache 2.0: http://www.apache.org/licenses/LICENSE-2.0
//

#ifndef ASDK_ACCESSIBILITY_DISABLE

#import <AsyncDisplayKit/_ASDisplayViewAccessiblity.h>
#import <AsyncDisplayKit/_ASDisplayView.h>
#import <AsyncDisplayKit/ASAvailability.h>
#import <AsyncDisplayKit/ASCollectionNode.h>
#import <AsyncDisplayKit/ASDisplayNodeExtras.h>
#import <AsyncDisplayKit/ASDisplayNodeInternal.h>
#import <AsyncDisplayKit/ASTableNode.h>

#import <queue>

NS_INLINE UIAccessibilityTraits InteractiveAccessibilityTraitsMask() {
  return UIAccessibilityTraitLink | UIAccessibilityTraitKeyboardKey | UIAccessibilityTraitButton;
}

#pragma mark - UIAccessibilityElement

@protocol ASAccessibilityElementPositioning

@property (nonatomic, readonly) CGRect accessibilityFrame;

@end

typedef NSComparisonResult (^SortAccessibilityElementsComparator)(id<ASAccessibilityElementPositioning>, id<ASAccessibilityElementPositioning>);

/// Sort accessiblity elements first by y and than by x origin.
static void SortAccessibilityElements(NSMutableArray *elements)
{
  ASDisplayNodeCAssertNotNil(elements, @"Should pass in a NSMutableArray");
  
  static SortAccessibilityElementsComparator comparator = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
      comparator = ^NSComparisonResult(id<ASAccessibilityElementPositioning> a, id<ASAccessibilityElementPositioning> b) {
        CGPoint originA = a.accessibilityFrame.origin;
        CGPoint originB = b.accessibilityFrame.origin;
        if (originA.y == originB.y) {
          if (originA.x == originB.x) {
            return NSOrderedSame;
          }
          return (originA.x < originB.x) ? NSOrderedAscending : NSOrderedDescending;
        }
        return (originA.y < originB.y) ? NSOrderedAscending : NSOrderedDescending;
      };
  });
  [elements sortUsingComparator:comparator];
}

@interface ASAccessibilityElement : UIAccessibilityElement<ASAccessibilityElementPositioning>

@property (nonatomic) ASDisplayNode *containerNode;
@property (nonatomic) ASDisplayNode *node;

+ (ASAccessibilityElement *)accessibilityElementWithContainerNode:(ASDisplayNode *)containerNode node:(ASDisplayNode *)node;

@end

@implementation ASAccessibilityElement

+ (ASAccessibilityElement *)accessibilityElementWithContainerNode:(ASDisplayNode *)containerNode node:(ASDisplayNode *)node
{
  ASAccessibilityElement *accessibilityElement = [[ASAccessibilityElement alloc] initWithAccessibilityContainer:containerNode.view];
  accessibilityElement.node = node;
  accessibilityElement.containerNode = containerNode;
  accessibilityElement.accessibilityIdentifier = node.accessibilityIdentifier;
  accessibilityElement.accessibilityLabel = node.accessibilityLabel;
  accessibilityElement.accessibilityHint = node.accessibilityHint;
  accessibilityElement.accessibilityValue = node.accessibilityValue;
  accessibilityElement.accessibilityTraits = node.accessibilityTraits;
  if (AS_AVAILABLE_IOS_TVOS(11, 11)) {
    accessibilityElement.accessibilityAttributedLabel = node.accessibilityAttributedLabel;
    accessibilityElement.accessibilityAttributedHint = node.accessibilityAttributedHint;
    accessibilityElement.accessibilityAttributedValue = node.accessibilityAttributedValue;
  }
  return accessibilityElement;
}

- (CGRect)accessibilityFrame
{
  CGRect accessibilityFrame = [self.containerNode convertRect:self.node.bounds fromNode:self.node];
  return UIAccessibilityConvertFrameToScreenCoordinates(accessibilityFrame, self.accessibilityContainer);
}

@end

#pragma mark - _ASDisplayView / UIAccessibilityContainer

@interface ASAccessibilityCustomAction : UIAccessibilityCustomAction<ASAccessibilityElementPositioning>

@property (nonatomic) ASDisplayNode *containerNode;
@property (nonatomic) ASDisplayNode *node;

@end

@implementation ASAccessibilityCustomAction

- (CGRect)accessibilityFrame
{
  ASDisplayNode *containerNode = self.containerNode;
  ASDisplayNode *node = self.node;
  ASDisplayNodeCAssertNotNil(containerNode, @"ASAccessibilityCustomAction needs a container node.");
  ASDisplayNodeCAssertNotNil(node, @"ASAccessibilityCustomAction needs a node.");
  CGRect accessibilityFrame = [containerNode convertRect:node.bounds fromNode:node];
  return UIAccessibilityConvertFrameToScreenCoordinates(accessibilityFrame, containerNode.view);
}

@end

/// Collect all subnodes for the given node by walking down the subnode tree and calculates the screen coordinates based on the containerNode and container. This is necessary for layer backed nodes or rasterrized subtrees as no UIView instance for this node exists.
static void CollectAccessibilityElementsForLayerBackedOrRasterizedNode(ASDisplayNode *containerNode, ASDisplayNode *node, NSMutableArray *elements)
{
  ASDisplayNodeCAssertNotNil(elements, @"Should pass in a NSMutableArray");

  // Iterate any node in the tree and either collect nodes that are accessibility elements
  // or leaf nodes that are accessibility containers
  ASDisplayNodePerformBlockOnEveryNodeBFS(node, ^(ASDisplayNode * _Nonnull currentNode) {
    if (currentNode != containerNode) {
      if (currentNode.isAccessibilityElement) {
        // For every subnode that is layer backed or it's supernode has subtree rasterization enabled
        // we have to create a UIAccessibilityElement as no view for this node exists
        UIAccessibilityElement *accessibilityElement = [ASAccessibilityElement accessibilityElementWithContainerNode:containerNode node:currentNode];
        [elements addObject:accessibilityElement];
      } else if (currentNode.subnodes.count == 0) {
        // In leaf nodes that are layer backed and acting as accessibility container we call
        // through to the accessibilityElements method.
        [elements addObjectsFromArray:currentNode.accessibilityElements];
      }
    }
  });
}

/// Called from the usual accessibility elements collection function for a container to collect all subnodes accessibilityLabels
static void AggregateSublabelsOrCustomActionsForContainerNode(ASDisplayNode *container, NSMutableArray *elements) {
  UIAccessibilityElement *accessiblityElement = [ASAccessibilityElement accessibilityElementWithContainerNode:container node:container];

  NSMutableArray<ASAccessibilityElement *> *labeledNodes = [[NSMutableArray alloc] init];
  NSMutableArray<ASAccessibilityCustomAction *> *actions = [[NSMutableArray alloc] init];

  // If the container does not have an accessibility label set, or if the label is meant for custom
  // actions only, then aggregate its subnodes' labels. Otherwise, treat the label as an overriden
  // value and do not perform the aggregation.
  BOOL shouldAggregateSubnodeLabels =
      (container.accessibilityLabel.length == 0) ||
      (container.accessibilityTraits & InteractiveAccessibilityTraitsMask());

  std::queue<ASDisplayNode *> queue;
  queue.push(container);
  ASDisplayNode *node = nil;
  while (!queue.empty()) {
    node = queue.front();
    queue.pop();

    // Only handle accessibility containers
    if (node != container && node.isAccessibilityContainer) {
      AggregateSublabelsOrCustomActionsForContainerNode(node, elements);
      continue;
    }

    // Aggregate either custom actions for specific accessibility traits or the accessibility labels
    // of the node
    if (node.accessibilityLabel.length > 0) {
      if (node.accessibilityTraits & InteractiveAccessibilityTraitsMask()) {
        ASAccessibilityCustomAction *action = [[ASAccessibilityCustomAction alloc] initWithName:node.accessibilityLabel target:node selector:@selector(performAccessibilityCustomAction:)];
        action.containerNode = node.supernode;
        action.node = node;
        [actions addObject:action];
      } else if (node == container || shouldAggregateSubnodeLabels) {
        // Even though not surfaced to UIKit, create a non-interactive element for purposes
        // of building sorted aggregated label.
        ASAccessibilityElement *nonInteractiveElement = [ASAccessibilityElement accessibilityElementWithContainerNode:container node:node];
        [labeledNodes addObject:nonInteractiveElement];
      }
    }

    for (ASDisplayNode *subnode in node.subnodes) {
      queue.push(subnode);
    }
  }

  SortAccessibilityElements(labeledNodes);

  if (AS_AVAILABLE_IOS_TVOS(11, 11)) {
    NSArray *attributedLabels = [labeledNodes valueForKey:@"accessibilityAttributedLabel"];
    NSMutableAttributedString *attributedLabel = [NSMutableAttributedString new];
    [attributedLabels enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
      if (idx != 0) {
        [attributedLabel appendAttributedString:[[NSAttributedString alloc] initWithString:@", "]];
      }
      [attributedLabel appendAttributedString:(NSAttributedString *)obj];
    }];
    accessiblityElement.accessibilityAttributedLabel = attributedLabel;
  } else {
    NSArray *labels = [labeledNodes valueForKey:@"accessibilityLabel"];
    accessiblityElement.accessibilityLabel = [labels componentsJoinedByString:@", "];
  }

  SortAccessibilityElements(actions);
  accessiblityElement.accessibilityCustomActions = actions;

  [elements addObject:accessiblityElement];
}

/// Collect all accessibliity elements for a given node
static void CollectAccessibilityElements(ASDisplayNode *node, NSMutableArray *elements)
{
  ASDisplayNodeCAssertNotNil(elements, @"Should pass in a NSMutableArray");

  BOOL anySubNodeIsCollection = (nil != ASDisplayNodeFindFirstNode(node,
      ^BOOL(ASDisplayNode *nodeToCheck) {
    return ASDynamicCast(nodeToCheck, ASCollectionNode) != nil ||
           ASDynamicCast(nodeToCheck, ASTableNode) != nil;
  }));

  // Handle an accessibility container (collects accessibility labels or custom actions)
  if (node.isAccessibilityContainer && !anySubNodeIsCollection) {
    AggregateSublabelsOrCustomActionsForContainerNode(node, elements);
    return;
  }
  
  // Handle a rasterize node
  if (node.rasterizesSubtree) {
    CollectAccessibilityElementsForLayerBackedOrRasterizedNode(node, node, elements);
    return;
  }

  // Go down each subnodes and collect all accessibility elements
  for (ASDisplayNode *subnode in node.subnodes) {
    if (subnode.isAccessibilityElement) {
      // An accessiblityElement can either be a UIView or a UIAccessibilityElement
      if (subnode.isLayerBacked) {
        // No view for layer backed nodes exist. It's necessary to create a UIAccessibilityElement that represents this node
        UIAccessibilityElement *accessiblityElement = [ASAccessibilityElement accessibilityElementWithContainerNode:node node:subnode];
        [elements addObject:accessiblityElement];
      } else {
        // Accessiblity element is not layer backed just add the view as accessibility element
        [elements addObject:subnode.view];
      }
    } else if (subnode.isLayerBacked) {
      // Go down the hierarchy for layer backed subnodes which are also accessibility container
      // and collect all of the UIAccessibilityElement
      CollectAccessibilityElementsForLayerBackedOrRasterizedNode(node, subnode, elements);
    } else if (subnode.accessibilityElementCount > 0) {
      // _ASDisplayView is itself a UIAccessibilityContainer just add it, UIKit will call the accessiblity
      // methods of the nodes _ASDisplayView
      [elements addObject:subnode.view];
    }
  }
}

@interface _ASDisplayView () {
  _ASDisplayViewAccessibilityFlags _accessibilityFlags;
}

@end

@implementation _ASDisplayView (UIAccessibilityContainer)

#pragma mark - UIAccessibility

- (NSInteger)accessibilityElementCount
{
  ASDisplayNodeAssertMainThread();
  if (_accessibilityFlags.inAccessibilityElementCount) {
    return [super accessibilityElementCount];
  }
  _accessibilityFlags.inAccessibilityElementCount = YES;
  NSInteger accessibilityElementCount = [self.asyncdisplaykit_node accessibilityElementCount];
  _accessibilityFlags.inAccessibilityElementCount = NO;
  return accessibilityElementCount;
}

- (NSInteger)indexOfAccessibilityElement:(id)element
{
  ASDisplayNodeAssertMainThread();
  if (_accessibilityFlags.inIndexOfAccessibilityElement) {
    return [super indexOfAccessibilityElement:element];
  }
  _accessibilityFlags.inIndexOfAccessibilityElement = YES;
  NSInteger indexOfAccessibilityElement = [self.asyncdisplaykit_node indexOfAccessibilityElement:element];
  _accessibilityFlags.inIndexOfAccessibilityElement = NO;
  return indexOfAccessibilityElement;
}

- (id)accessibilityElementAtIndex:(NSInteger)index
{
  ASDisplayNodeAssertMainThread();
  if (_accessibilityFlags.inAccessibilityElementAtIndex) {
    return [super accessibilityElementAtIndex:index];
  }
  _accessibilityFlags.inAccessibilityElementAtIndex = YES;
  id accessibilityElement = [self.asyncdisplaykit_node accessibilityElementAtIndex:index];
  _accessibilityFlags.inAccessibilityElementAtIndex = NO;
  return accessibilityElement;
}

- (void)setAccessibilityElements:(NSArray *)accessibilityElements
{
  ASDisplayNodeAssertMainThread();
  if (_accessibilityFlags.inSetAccessibilityElements) {
    return [super setAccessibilityElements:accessibilityElements];
  }
  _accessibilityFlags.inSetAccessibilityElements = YES;
  [self.asyncdisplaykit_node setAccessibilityElements:accessibilityElements];
  _accessibilityFlags.inSetAccessibilityElements = NO;
}

- (NSArray *)accessibilityElements
{
  ASDisplayNodeAssertMainThread();
  
  ASDisplayNode *viewNode = self.asyncdisplaykit_node;
  if (viewNode == nil) {
    return @[];
  }

  return [viewNode accessibilityElements];
}

@end

@implementation ASDisplayNode (AccessibilityInternal)

- (NSInteger)accessibilityElementCount
{
  return [_view accessibilityElementCount];
}

- (NSInteger)indexOfAccessibilityElement:(id)element
{
  return [_view indexOfAccessibilityElement:element];
}

- (id)accessibilityElementAtIndex:(NSInteger)index
{
  return [_view accessibilityElementAtIndex:index];
}

- (void)setAccessibilityElements:(NSArray *)accessibilityElements
{
  _accessibilityElements = accessibilityElements;
  [_view setAccessibilityElements:accessibilityElements];
}

- (NSArray *)accessibilityElements
{
  if (!self.isNodeLoaded) {
    ASDisplayNodeFailAssert(@"Cannot access accessibilityElements since node is not loaded");
    return @[];
  }

  if (_accessibilityElements == nil) {
    NSMutableArray *accessibilityElements = [[NSMutableArray alloc] init];
    CollectAccessibilityElements(self, accessibilityElements);
    SortAccessibilityElements(accessibilityElements);
    _accessibilityElements = accessibilityElements;
  }
  return _accessibilityElements;
}

@end

@implementation _ASDisplayView (UIAccessibilityAction)

- (BOOL)accessibilityActivate
{
  return [self.asyncdisplaykit_node accessibilityActivate];
}

- (void)accessibilityIncrement
{
  [self.asyncdisplaykit_node accessibilityIncrement];
}

- (void)accessibilityDecrement
{
  [self.asyncdisplaykit_node accessibilityDecrement];
}

- (BOOL)accessibilityScroll:(UIAccessibilityScrollDirection)direction
{
  return [self.asyncdisplaykit_node accessibilityScroll:direction];
}

- (BOOL)accessibilityPerformEscape
{
  return [self.asyncdisplaykit_node accessibilityPerformEscape];
}

- (BOOL)accessibilityPerformMagicTap
{
  return [self.asyncdisplaykit_node accessibilityPerformMagicTap];
}

@end

#endif
